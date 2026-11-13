//go:build !noembedetcd

// Licensed to the LF AI & Data foundation under one
// or more contributor license agreements. See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership. The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License. You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// limitations under the License.
// See the License for the specific language governing permissions and

package etcdkv

import (
	"time"

	"go.etcd.io/etcd/server/v3/embed"

	"github.com/milvus-io/milvus/pkg/v3/kv"
	"github.com/milvus-io/milvus/pkg/v3/util/paramtable"
)

func newEmbedWatchKV(rootPath string, etcdCfg *paramtable.EtcdConfig) (kv.WatchKV, error) {
	path := etcdCfg.ConfigPath.GetValue()
	var cfg *embed.Config
	if len(path) > 0 {
		cfgFromFile, err := embed.ConfigFromFile(path)
		if err != nil {
			return nil, err
		}
		cfg = cfgFromFile
	} else {
		cfg = embed.NewConfig()
	}
	cfg.Dir = etcdCfg.DataDir.GetValue()
	watchKv, err := NewEmbededEtcdKV(cfg, rootPath, WithRequestTimeout(etcdCfg.RequestTimeout.GetAsDuration(time.Millisecond)))
	if err != nil {
		return nil, err
	}
	return watchKv, nil
}
