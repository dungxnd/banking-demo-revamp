package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/caarlos0/env/v11"
	"github.com/go-chi/chi/v5"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	internnats "banking-demo/internal/nats"
	"banking-demo/internal/health"
	ilogging "banking-demo/internal/logging"
	"banking-demo/internal/metrics"
	iredis "banking-demo/internal/redis"
	"banking-demo/internal/service"
	"banking-demo/internal/tracing"
)

const (
	serviceName   = "account-service"
	subjectPrefix = "banking.account"
)

type config struct {
	Port         string `env:"PORT"         envDefault:"8002"`
	NATSURL      string `env:"NATS_URL"     envDefault:"nats://nats:4222"`
	DatabaseURL  string `env:"DATABASE_URL" envDefault:"postgresql://banking:bankingpass@postgres:5432/banking"`
	RedisURL     string `env:"REDIS_URL"    envDefault:"redis://redis:6379/0"`
	AdminSecret  string `env:"ADMIN_SECRET" envDefault:"banking-admin-2025"`
	OTLPEndpoint string `env:"OTEL_EXPORTER_OTLP_ENDPOINT"`
}

func main() {
	var cfg config
	if err := env.Parse(&cfg); err != nil {
		fmt.Fprintf(os.Stderr, "fatal: parse config: %v\n", err)
		os.Exit(1)
	}
	if err := run(context.Background(), cfg); err != nil {
		os.Exit(1)
	}
}

func run(ctx context.Context, cfg config) error {
	logger := ilogging.NewLogger(serviceName)

	shutdownTracing := tracing.Init(serviceName, cfg.OTLPEndpoint, logger)
	defer shutdownTracing(context.Background())

	d, cleanup, err := service.InitDeps(ctx, cfg.DatabaseURL, cfg.RedisURL, logger)
	if err != nil {
		return err
	}
	defer cleanup()
	d.LogPoolStatus(logger)

	// Connect to NATS once — shared by the micro RPC Consumer and the JetStream
	// balance-projection pull consumer.
	m := metrics.NewConsumerMetrics(serviceName)
	nc, err := internnats.Connect(cfg.NATSURL, serviceName, logger, m.ReconnectsTotal.Inc)
	if err != nil {
		logger.Error("nats_connect_failed", "error", err.Error())
		return err
	}
	defer nc.Drain()

	// Start the JetStream balance projection pull consumer (Tier 3).
	// Gracefully degrades when JetStream is not available (no -js flag on NATS server):
	// account-service continues to serve balance via the Tier 2 Redis hash + DB fallback.
	if js, jsErr := internnats.InitStream(ctx, nc); jsErr != nil {
		logger.Warn("jetstream_unavailable_balance_projection_disabled",
			"error", jsErr.Error(),
			"note", "start NATS with -js to enable durable balance projection",
		)
	} else {
		go runBalanceProjection(ctx, js, d.RedisClient, logger)
	}

	requireSession := internnats.SessionMiddleware(d.RedisClient)
	requireAdmin := internnats.AdminMiddleware(cfg.AdminSecret, d.RedisClient)

	consumer := internnats.NewConsumer(cfg.NATSURL, serviceName, subjectPrefix, logger,
		internnats.WithConn(nc), // share pre-connected conn
		internnats.WithMetrics(m),
		// User-facing (session-guarded)
		internnats.WithHandler("me", requireSession(handleMe(d.BDB, logger))),
		internnats.WithHandler("balance", requireSession(handleBalance(d.BDB, d.RedisClient, logger))),
		internnats.WithHandler("lookup", requireSession(handleLookup(d.BDB, logger))),
		// Admin (admin-secret + session guarded)
		internnats.WithHandler("stats", requireAdmin(handleAdminStats(d.BDB, logger))),
		internnats.WithHandler("users", requireAdmin(handleAdminUsers(d.BDB, logger))),
		internnats.WithHandler("transfers", requireAdmin(handleAdminTransfers(d.BDB, logger))),
		internnats.WithHandler("notifications", requireAdmin(handleAdminNotifications(d.BDB, logger))),
		internnats.WithHandler("user-detail", requireAdmin(handleAdminUserDetail(d.BDB, logger))),
		// Health
		internnats.WithHandler("health", health.NATSHandler(serviceName, d.Pool, d.RedisClient)),
	)

	router := chi.NewRouter()
	router.Get("/health", health.HTTPHandler(serviceName, d.Pool, d.RedisClient))
	router.Handle("/metrics", promhttp.Handler())

	server := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           router,
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      30 * time.Second,
	}

	return service.NewRunner(consumer, server, logger).Run(ctx)
}

// runBalanceProjection runs the durable JetStream pull consumer that keeps the
// Redis "balance" hash up-to-date from the BANKING_EVENTS stream.
//
// On a cold start (Redis wiped, new deploy) DeliverAllPolicy replays the full
// event log so the hash is rebuilt without a DB round-trip. On subsequent
// restarts the durable offset ensures only new events are replayed.
//
// The goroutine is started once per process and exits when ctx is cancelled.
// Errors are logged but not fatal — the Tier 2 Redis pipeline + DB fallback
// in handleBalance keeps balance reads working while this catches up.
func runBalanceProjection(ctx context.Context, js jetstream.JetStream, rc *iredis.Client, logger *slog.Logger) {
	cons, err := internnats.NewBalanceConsumer(ctx, js)
	if err != nil {
		logger.Error("balance_projection_consumer_failed", "error", err.Error())
		return
	}

	consCtx, err := cons.Consume(func(msg jetstream.Msg) {
		var evt iredis.TransferCompleted
		if err := json.Unmarshal(msg.Data(), &evt); err != nil {
			logger.Error("balance_projection_decode_error", "error", err.Error())
			_ = msg.Nak()
			return
		}

		// SetBalanceBatch pipelines HSET for both users in a single Redis round-trip.
		// All Redis key strings are owned by internal/redis; no key literals here.
		if err := iredis.SetBalanceBatch(ctx, rc, evt.SenderID, evt.SenderBalance, evt.ReceiverID, evt.ReceiverBalance); err != nil {
			logger.Error("balance_projection_redis_error", "transfer_id", evt.TransferID, "error", err.Error())
			_ = msg.NakWithDelay(5 * time.Second) // retry after 5 s; does not consume BackOff slots
			return
		}

		logger.Info("balance_projection_updated",
			"transfer_id", evt.TransferID,
			"sender_id", evt.SenderID,
			"receiver_id", evt.ReceiverID,
		)
		_ = msg.Ack()
	})
	if err != nil {
		logger.Error("balance_projection_consume_failed", "error", err.Error())
		return
	}
	defer consCtx.Stop()

	logger.Info("balance_projection_started",
		"stream", internnats.StreamName,
		"consumer", internnats.ConsumerBalanceProjection,
	)
	<-ctx.Done()
	logger.Info("balance_projection_stopped")
}
