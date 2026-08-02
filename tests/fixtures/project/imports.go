package fixture

import (
	alias "example.com/project/internal/service"
	_ "example.com/project/internal/generated"
)

var _ = alias.Run
