// Copyright 2017 The Gitea Authors. All rights reserved.
// Use of this source code is governed by a MIT-style
// license that can be found in the LICENSE file.

package git

import (
	"testing"
	"time"
	"github.com/stretchr/testify/assert"
)

func TestGetLatestCommitTime(t *testing.T) {
	lct, _ := GetLatestCommitTime(".")
	assert.True(t, lct.Unix() < time.Now().Unix())
}
