//go:build with_jemalloc && linux
// +build with_jemalloc,linux

package cgosymbolizer

import (
	"log"

	"github.com/prometheus/client_golang/prometheus"
)

// RegisterJemallocStatsMetrics registers the jemalloc metrics with the given namespace, subsystem, and constLabels.
func RegisterJemallocStatsMetrics(namespace string, r prometheus.Registerer) {
	if !IsJemallocStatsEnabled() {
		log.Println("jemalloc stats is not enabled, skipping metric registration")
		return
	}
	log.Println("register jemalloc stats metrics")

	subsystem := "jemalloc"
	for _, c := range []prometheus.Collector{
		prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Namespace: namespace,
			Subsystem: subsystem,
			Name:      "allocated",
		}, func() float64 {
			return float64(GetAllocatedMemory())
		}),

		prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Namespace: namespace,
			Subsystem: subsystem,
			Name:      "active",
		}, func() float64 {
			return float64(GetActiveMemory())
		}),

		prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Namespace: namespace,
			Subsystem: subsystem,
			Name:      "metadata",
		}, func() float64 {
			return float64(GetMetadataMemory())
		}),

		prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Namespace: namespace,
			Subsystem: subsystem,
			Name:      "metadata_thp",
		}, func() float64 {
			return float64(GetMetadataThpMemory())
		}),

		prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Namespace: namespace,
			Subsystem: subsystem,
			Name:      "resident",
		}, func() float64 {
			return float64(GetResidentMemory())
		}),

		prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Namespace: namespace,
			Subsystem: subsystem,
			Name:      "mapped",
		}, func() float64 {
			return float64(GetMappedMemory())
		}),

		prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Namespace: namespace,
			Subsystem: subsystem,
			Name:      "retained",
		}, func() float64 {
			return float64(GetRetainedMemory())
		}),

		prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Namespace: namespace,
			Subsystem: subsystem,
			Name:      "zero_reallocs",
		}, func() float64 {
			return float64(GetZeroReallocs())
		}),

		prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Namespace: namespace,
			Subsystem: subsystem,
			Name:      "background_thread_num_threads",
		}, func() float64 {
			return float64(GetBackgroundThreadNumThreads())
		}),

		prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Namespace: namespace,
			Subsystem: subsystem,
			Name:      "background_thread_num_runs",
		}, func() float64 {
			return float64(GetBackgroundThreadNumRuns())
		}),

		prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Namespace: namespace,
			Subsystem: subsystem,
			Name:      "background_thread_run_interval",
		}, func() float64 {
			return float64(GetBackgroundThreadRunInterval())
		}),
	} {
		r.MustRegister(c)
	}
}
