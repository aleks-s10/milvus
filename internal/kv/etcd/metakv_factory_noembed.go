//go:build noembedetcd

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
	"github.com/cockroachdb/errors"

	"github.com/milvus-io/milvus/pkg/v3/kv"
	"github.com/milvus-io/milvus/pkg/v3/util/paramtable"
)

// ErrEmbedEtcdNotCompiled is returned when etcd.use.embed=true is requested
// from a binary built with the noembedetcd tag.
var ErrEmbedEtcdNotCompiled = errors.New("embedded etcd is not supported in this build (built with -tags noembedetcd); set etcd.use.embed=false and configure external etcd endpoints")

func newEmbedWatchKV(string, *paramtable.EtcdConfig) (kv.WatchKV, error) {
	return nil, ErrEmbedEtcdNotCompiled
}
