package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strconv"
	"strings"

	"github.com/stephenafamo/bob"
	"github.com/stephenafamo/bob/dialect/psql"
	"github.com/stephenafamo/bob/dialect/psql/sm"
	"github.com/stephenafamo/scan"

	"banking-demo/internal/db"
	ilogging "banking-demo/internal/logging"
	internnats "banking-demo/internal/nats"
	iredis "banking-demo/internal/redis"
)

// handleMe returns the authenticated user's profile.
// Session is already resolved by RequireSession middleware; user ID is in context.
func handleMe(bdb bob.DB, logger *slog.Logger) internnats.Handler {
	return func(ctx context.Context, _ string, _ json.RawMessage, _ map[string]string) (any, error) {
		userID, _ := internnats.UserIDFromContext(ctx)
		u, err := db.QueryUser(ctx, bdb, psql.Quote("id"), userID)
		if db.IsNotFound(err) {
			return internnats.Reply(404, map[string]string{"detail": "User not found"}), nil
		}
		if err != nil {
			return nil, fmt.Errorf("query user: %w", err)
		}
		logger.Info("me_request", "user_id", u.ID)
		return internnats.Reply(200, userToAdminView(u)), nil
	}
}

// handleBalance serves the user's current balance.
// Read model: first tries the "balance" Redis Hash (written by transfer-service
// post-commit pipeline). Falls back to PostgreSQL on a cold start or Redis restart,
// and back-fills the hash so the next request hits the cache.
func handleBalance(bdb bob.DB, rc *iredis.Client, logger *slog.Logger) internnats.Handler {
	return func(ctx context.Context, _ string, _ json.RawMessage, _ map[string]string) (any, error) {
		userID, _ := internnats.UserIDFromContext(ctx)

		balance, ok, err := iredis.GetBalance(ctx, rc, userID)
		if err != nil {
			return nil, fmt.Errorf("get balance: %w", err)
		}
		if !ok {
			// Cache miss — fall back to DB and warm the read model.
			balance, err = queryBalanceFromDB(ctx, bdb, userID)
			if db.IsNotFound(err) {
				return internnats.Reply(404, map[string]string{"detail": "User not found"}), nil
			}
			if err != nil {
				return nil, fmt.Errorf("get balance: %w", err)
			}
			_ = iredis.SetBalance(ctx, rc, userID, balance)
		}
		logger.Info("balance_request", "user_id", userID, "balance", ilogging.MaskAmount(balance))
		return internnats.Reply(200, map[string]any{"balance": balance}), nil
	}
}

// queryBalanceFromDB fetches the balance column for a single user from PostgreSQL.
func queryBalanceFromDB(ctx context.Context, bdb bob.DB, userID int) (int, error) {
	return bob.One(ctx, bdb,
		psql.Select(
			sm.Columns("balance"),
			sm.From("users"),
			sm.Where(psql.Quote("id").EQ(psql.Arg(userID))),
		),
		scan.SingleColumnMapper[int],
	)
}

// lookupPayload is the request body for the lookup action.
// Exactly one of the three fields must be non-empty.
type lookupPayload struct {
	AccountNumber string `json:"account_number"`
	Phone         string `json:"phone"`
	Username      string `json:"username"`
}

// handleLookup resolves a user's public profile (id, account_number, username)
// by account_number, phone, or username. Returns 400 if no identifier is provided.
func handleLookup(bdb bob.DB, logger *slog.Logger) internnats.Handler {
	return func(ctx context.Context, _ string, raw json.RawMessage, _ map[string]string) (any, error) {
		// userID validated by RequireSession middleware; not needed for lookup itself
		var p lookupPayload
		if err := json.Unmarshal(raw, &p); err != nil {
			return internnats.Reply(400, map[string]string{"detail": "invalid payload"}), nil
		}
		p.AccountNumber = strings.TrimSpace(p.AccountNumber)
		p.Phone = strings.TrimSpace(p.Phone)
		p.Username = strings.TrimSpace(p.Username)
		if p.AccountNumber == "" && p.Phone == "" && p.Username == "" {
			return internnats.Reply(400, map[string]string{"detail": "provide account_number, phone, or username"}), nil
		}

		col, val := db.UserIdentifierCol(p.AccountNumber, p.Phone, p.Username)
		u, err := db.QueryUser(ctx, bdb, col, val)
		if db.IsNotFound(err) {
			return internnats.Reply(404, map[string]string{"detail": "User not found"}), nil
		}
		if err != nil {
			return nil, fmt.Errorf("lookup user: %w", err)
		}
		logger.Info("lookup_request", "account_number", ilogging.MaskAccount(u.AccountNumber))
		return internnats.Reply(200, map[string]any{
			"id": u.ID, "account_number": u.AccountNumber, "username": u.Username,
		}), nil
	}
}

// maxPage caps the deepest page allowed for OFFSET-based pagination.
// OFFSET scans and discards all preceding rows — at page 500
// with size 20, the DB reads 10 000 rows to discard 9 980. Cursor-based
// pagination (keyed on id) is the correct solution for very deep pages, but
// that requires an API contract change (client sends after_id instead of page).
// Until then, cap page depth to prevent runaway OFFSET scans on admin endpoints.
const maxPage = 200

// paginate parses page/size from a JSON query-param map.
// Defaults: page=1, size=20. size is capped at 100. page is capped at maxPage.
func paginate(raw json.RawMessage) (page, size int) {
	page, size = 1, 20
	var m map[string]string
	if err := json.Unmarshal(raw, &m); err != nil {
		return
	}
	if v, err := strconv.Atoi(m["page"]); err == nil && v > 0 {
		page = v
	}
	if v, err := strconv.Atoi(m["size"]); err == nil && v > 0 && v <= 100 {
		size = v
	}
	if page > maxPage {
		page = maxPage
	}
	return
}
