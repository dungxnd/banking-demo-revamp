package main

import (
	"context"
	"log/slog"

	"banking-demo/internal/tracing"
)

// initTracing initialises the global OTel tracer for the producer and returns
// the shutdown function to defer at the end of main.
func initTracing(cfg config, logger *slog.Logger) func(context.Context) {
	return tracing.Init(serviceName, cfg.OTLPEndpoint, logger)
}
