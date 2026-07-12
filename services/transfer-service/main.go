package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/caarlos0/env/v11"
	"github.com/go-chi/chi/v5"
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
	serviceName   = "transfer-service"
	subjectPrefix = "banking.transfer"
)

type config struct {
	Port         string `env:"PORT"         envDefault:"8003"`
	NATSURL      string `env:"NATS_URL"     envDefault:"nats://nats:4222"`
	DatabaseURL  string `env:"DATABASE_URL" envDefault:"postgresql://banking:bankingpass@postgres:5432/banking"`
	RedisURL     string `env:"REDIS_URL"    envDefault:"redis://redis:6379/0"`
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

	// Connect to NATS once — the same connection is shared by the micro RPC
	// Consumer and the JetStream publisher. This halves the number of TCP
	// connections to NATS and keeps reconnect state in one place.
	m := metrics.NewConsumerMetrics(serviceName)
	nc, err := internnats.Connect(cfg.NATSURL, serviceName, logger, m.ReconnectsTotal.Inc)
	if err != nil {
		logger.Error("nats_connect_failed", "error", err.Error())
		return err
	}
	defer nc.Drain()

	// Init BANKING_EVENTS stream (idempotent — safe on every boot).
	// If JetStream is not enabled on the server (no -js flag), InitStream returns
	// an error and we log a warning then proceed without durable event publishing —
	// the Tier 2 Redis pipeline still works and no transfer is lost.
	js, jsErr := internnats.InitStream(ctx, nc)
	if jsErr != nil {
		logger.Warn("jetstream_unavailable_transfer_events_disabled",
			"error", jsErr.Error(),
			"note", "start NATS with -js to enable durable event publishing",
		)
	}

	// Wrap the JetStream publish into a plain callback so handleTransfer does not
	// import the jetstream package — infrastructure details stay in main.go.
	var publishEvent transferEventPublisher
	if js != nil {
		publishEvent = func(ctx context.Context, evt iredis.TransferCompleted) error {
			return internnats.PublishTransferEvent(ctx, js, evt)
		}
	}

	requireSession := internnats.SessionMiddleware(d.RedisClient)

	consumer := internnats.NewConsumer(cfg.NATSURL, serviceName, subjectPrefix, logger,
		internnats.WithConn(nc), // share pre-connected conn
		internnats.WithMetrics(m),
		internnats.WithHandler("transfer", requireSession(handleTransfer(d.BDB, d.RedisClient, publishEvent, logger))),
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
