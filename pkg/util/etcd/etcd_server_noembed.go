//go:build noembedetcd

package etcd

import (
	"github.com/cockroachdb/errors"
	clientv3 "go.etcd.io/etcd/client/v3"
)

// ErrEmbedEtcdNotCompiled is returned when embedded etcd is requested from a
// binary built with the noembedetcd tag.
var ErrEmbedEtcdNotCompiled = errors.New("embedded etcd is not supported in this build (built with -tags noembedetcd); use an external etcd")

// GetEmbedEtcdClient always fails in noembedetcd builds.
func GetEmbedEtcdClient() (*clientv3.Client, error) {
	return nil, ErrEmbedEtcdNotCompiled
}

// InitEtcdServer fails if useEmbedEtcd is true; otherwise it is a no-op.
func InitEtcdServer(useEmbedEtcd bool, configPath, dataDir, logPath, logLevel string) error {
	if useEmbedEtcd {
		return ErrEmbedEtcdNotCompiled
	}
	return nil
}

// HasServer is always false in noembedetcd builds.
func HasServer() bool { return false }

// StopEtcdServer is a no-op in noembedetcd builds.
func StopEtcdServer() {}
