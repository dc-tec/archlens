package fixture

func helper() int {
	return 42
}

func Run() int {
	return helper()
}

type Manager struct{}
