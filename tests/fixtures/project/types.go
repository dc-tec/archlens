package fixture

type Contract interface {
	First() error
	Second(value int) string
}

type Point struct {
	Left, Right int
	Embedded
	pkg.Qualified
}
