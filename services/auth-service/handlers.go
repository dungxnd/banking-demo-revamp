package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"

	"github.com/stephenafamo/bob"
	"github.com/stephenafamo/bob/dialect/psql"
	"github.com/stephenafamo/bob/dialect/psql/im"
	"github.com/stephenafamo/scan"

	internnats "banking-demo/internal/nats"
	"banking-demo/internal/auth"
	"banking-demo/internal/db"
	ilogging "banking-demo/internal/logging"
	iredis "banking-demo/internal/redis"
)

// credentials is the shared JSON payload for both register and login.
type credentials struct {
	Phone    string `json:"phone"`
	Username string `json:"username"`
	Password string `json:"password"`
}

// handleRegister creates a new user account.
// Validates that phone is all-digits, bcrypt-hashes the password, then inserts
// the user row. Account number uniqueness is enforced by the DB via ON CONFLICT
// DO NOTHING — no pre-check SELECT loop is needed, which eliminates up to 20
// extra round-trips per registration.
//
// The phone uniqueness pre-check SELECT is intentionally absent: the INSERT already
// carries a UNIQUE constraint on phone, so a duplicate phone raises SQLSTATE 23505
// which IsUniqueViolation catches below. Removing the pre-check saves one DB
// round-trip per registration request (≈1ms at this load level).
func handleRegister(bdb bob.DB, logger *slog.Logger) internnats.Handler {
	return func(ctx context.Context, _ string, raw json.RawMessage, _ map[string]string) (any, error) {
		var p credentials
		if err := json.Unmarshal(raw, &p); err != nil {
			return internnats.Reply(400, map[string]string{"detail": "invalid payload"}), nil
		}
		phone := strings.TrimSpace(p.Phone)
		if !isDigits(phone) {
			return internnats.Reply(400, map[string]string{"detail": "Phone must be digits only"}), nil
		}

		// Hash password once before the insert loop (bcrypt is expensive).
		pwHash, err := auth.HashPassword(p.Password)
		if err != nil {
			return nil, fmt.Errorf("hash password: %w", err)
		}
		username := strings.TrimSpace(p.Username)

		// Insert with a fresh random account_number on each attempt.
		// ON CONFLICT (account_number) DO NOTHING means a colliding account
		// number returns no rows (sql.ErrNoRows) → retry with a new candidate.
		// Collision probability is ~1 in 10^12, so one attempt almost always
		// succeeds. This eliminates the old SELECT-per-candidate loop entirely.
		const maxAttempts = 20
		var u db.User
		for range maxAttempts {
			acctNumber := randomDigits(12)
			u, err = bob.One(ctx, bdb,
				psql.Insert(
					im.Into("users", "phone", "account_number", "username", "password_hash"),
					im.Values(psql.Arg(phone), psql.Arg(acctNumber), psql.Arg(username), psql.Arg(pwHash)),
					im.OnConflict("account_number").DoNothing(),
					im.Returning("id", "phone", "account_number", "username", "balance"),
				),
				scan.StructMapper[db.User](),
			)
			if db.IsUniqueViolation(err) {
				// phone UNIQUE constraint fired — concurrent registration won the race.
				return internnats.Reply(409, map[string]string{"detail": "Phone already registered"}), nil
			}
			if db.IsNotFound(err) {
				// account_number conflicted → DO NOTHING returned no rows. Retry.
				continue
			}
			if err != nil {
				return nil, fmt.Errorf("insert user: %w", err)
			}
			// Successful insert.
			logger.Info("register_success", "user_id", u.ID, "username", u.Username)
			return internnats.Reply(201, map[string]any{
				"id": u.ID, "phone": ilogging.MaskPhone(u.Phone),
				"username": u.Username, "account_number": u.AccountNumber, "balance": u.Balance,
			}), nil
		}
		return internnats.Reply(503, map[string]string{"detail": "Cannot generate account number"}), nil
	}
}

// handleLogin authenticates a user by phone or username and returns a session token.
// Checks the Redis user cache first; falls back to PostgreSQL on a miss and back-fills the cache.
// Returns 401 for unknown credentials or wrong password; never distinguishes between the two.
func handleLogin(bdb bob.DB, redisClient *iredis.Client, logger *slog.Logger) internnats.Handler {
	return func(ctx context.Context, _ string, raw json.RawMessage, _ map[string]string) (any, error) {
		var p credentials
		if err := json.Unmarshal(raw, &p); err != nil {
			return internnats.Reply(400, map[string]string{"detail": "invalid payload"}), nil
		}
		phone, username := strings.TrimSpace(p.Phone), strings.TrimSpace(p.Username)
		if phone == "" && username == "" {
			return internnats.Reply(400, map[string]string{"detail": "Missing phone/username"}), nil
		}
		if phone != "" && !isDigits(phone) {
			return internnats.Reply(400, map[string]string{"detail": "Phone must be digits only"}), nil
		}

		// Lookup cache by the identifier that was provided.
		var (
			cached *iredis.CachedUser
			err    error
		)
		if phone != "" {
			cached, err = iredis.GetUserCacheByPhone(ctx, redisClient, phone)
		} else {
			cached, err = iredis.GetUserCacheByUsername(ctx, redisClient, username)
		}
		if err != nil {
			return nil, fmt.Errorf("get user cache: %w", err)
		}

		var u *iredis.CachedUser
		if cached != nil {
			u = cached
		} else {
			col, val := db.UserIdentifierCol("", phone, username)
			row, err := db.QueryUser(ctx, bdb, col, val)
			if db.IsNotFound(err) {
				logger.Info("login_failed", "reason", "user_not_found")
				return internnats.Reply(401, map[string]string{"detail": "Invalid credentials"}), nil
			}
			if err != nil {
				return nil, fmt.Errorf("query user: %w", err)
			}
			cu := iredis.CachedUser{
				ID: int(row.ID), Phone: row.Phone, Username: row.Username,
				AccountNumber: row.AccountNumber, PasswordHash: row.PasswordHash,
				Balance: int(row.Balance), IsAdmin: row.IsAdmin,
			}
			if cacheErr := iredis.SetUserCache(ctx, redisClient, cu); cacheErr != nil {
				logger.Warn("set_user_cache_failed", "user_id", cu.ID, "error", cacheErr.Error())
			}
			u = &cu
		}

		if !auth.VerifyPassword(p.Password, u.PasswordHash) {
			logger.Info("login_failed", "reason", "invalid_password", "user_id", u.ID)
			return internnats.Reply(401, map[string]string{"detail": "Invalid credentials"}), nil
		}
		sid, err := iredis.CreateSession(ctx, redisClient, u.ID)
		if err != nil {
			return nil, fmt.Errorf("create session: %w", err)
		}
		logger.Info("login_success", "user_id", u.ID, "username", u.Username)
		return internnats.Reply(200, map[string]any{
			"session": sid, "phone": ilogging.MaskPhone(u.Phone),
			"username": u.Username, "account_number": u.AccountNumber,
			"balance": u.Balance, "is_admin": u.IsAdmin,
		}), nil
	}
}

// handleLogout deletes the caller's session token, invalidating it immediately.
// The session is validated by RequireSession middleware before this runs, so
// headers["x-session"] is guaranteed to be a live token at this point.
// Returns 204 on success (no body — the session resource is gone).
func handleLogout(redisClient *iredis.Client) internnats.Handler {
	return func(ctx context.Context, _ string, _ json.RawMessage, headers map[string]string) (any, error) {
		sid := headers["x-session"]
		if err := iredis.DeleteSession(ctx, redisClient, sid); err != nil {
			return nil, fmt.Errorf("delete session: %w", err)
		}
		return internnats.Reply(204, nil), nil
	}
}


// isDigits reports whether s is non-empty and contains only ASCII decimal digits.
func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
