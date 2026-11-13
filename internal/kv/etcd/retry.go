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

import "time"

const (
	defaultRetryCount    = 3
	defaultRetryInterval = 1 * time.Second
)

func retry(attempts int, sleep time.Duration, fn func() error) error {
	for i := 0; ; i++ {
		err := fn()
		if err == nil || i >= (attempts-1) {
			return err
		}
		time.Sleep(sleep)
	}
}
