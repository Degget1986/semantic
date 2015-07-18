struct Fix: CustomDebugStringConvertible, CustomDocConvertible, CustomStringConvertible, Equatable, FixpointType {
	init(_ roll: () -> Syntax<Fix>) {
		self.roll = roll
	}
	init(_ out: Syntax<Fix>) {
		self.init { out }
	}

	let roll: () -> Syntax<Fix>

	var out: Syntax<Fix> {
		return roll()
	}

	var debugDescription: String {
		return cata { String(reflecting: $0) } (self)
	}

	var doc: Doc<Pretty> {
		return cata { (syntax: Syntax<Doc<Pretty>>) in syntax.doc } (self)
	}

	var description: String {
		return cata { String($0) } (self)
	}
}

func == (left: Fix, right: Fix) -> Bool {
	return left.out == right.out
}


enum Syntax<Payload>: AlgebraicType, CustomDebugStringConvertible, CustomDocConvertible {
	case Apply(Payload, [Payload])
	case Abstract([Payload], Payload)
	case Assign(String, Payload)
	case Variable(String)
	case Literal(String)
	case Group(Payload, [Payload])

	func map<T>(@noescape transform: Payload -> T) -> Syntax<T> {
		switch self {
		case let .Apply(f, args):
			return .Apply(transform(f), args.map(transform))
		case let .Abstract(parameters, body):
			return .Abstract(parameters.map(transform), transform(body))
		case let .Assign(n, v):
			return .Assign(n, transform(v))
		case let .Variable(n):
			return .Variable(n)
		case let .Literal(v):
			return .Literal(v)
		case let .Group(n, v):
			return .Group(transform(n), v.map(transform))
		}
	}

	typealias Recur = Payload

	var debugDescription: String {
		switch self {
		case let .Apply(f, vs):
			let s = ", ".join(vs.map { String($0) })
			return ".Apply(\(f), [ \(s) ])"
		case let .Abstract(parameters, body):
			let s = ", ".join(parameters.map { String($0) })
			return ".Abstract([ \(s) ], \(body))"
		case let .Assign(n, v):
			return ".Assign(\(n), \(v))"
		case let .Variable(n):
			return ".Variable(\(n))"
		case let .Literal(s):
			return ".Literal(\(s))"
		case let .Group(n, vs):
			let s = ", ".join(vs.map { String($0) })
			return ".Group(\(n), [ \(s) ])"
		}
	}

	var doc: Doc<Pretty> {
		switch self {
		case let .Apply(f, vs):
			return .Horizontal([
				Pretty(f),
				Pretty.Wrap(Pretty.Text("("), Pretty.Join(Pretty.Text(", "), vs.map(Pretty.init)), Pretty.Text(")"))
			])
		case let .Abstract(parameters, body):
			return .Horizontal([
				Pretty.Text("λ"),
				Pretty.Join(Pretty.Text(", "), parameters.map(Pretty.init)),
				Pretty.Text("."),
				Pretty(body)
			])
		case let .Assign(n, v):
			return .Horizontal([ .Text(n), .Text("="), Pretty(v) ])
		case let .Variable(n):
			return .Text(n)
		case let .Literal(s):
			return .Text(s)
		case let .Group(n, vs):
			return .Horizontal([
				Pretty(n),
				Pretty.Wrap(.Text("{"), Pretty.Vertical(vs.map(Pretty.init)), .Text("}"))
			])
		}
	}
}

func == <F: Equatable> (left: Syntax<F>, right: Syntax<F>) -> Bool {
	switch (left, right) {
	case let (.Apply(a, aa), .Apply(b, bb)):
		return a == b && aa == bb
	case let (.Abstract(p1, b1), .Abstract(p2, b2)):
		return p1 == p2 && b1 == b2
	case let (.Assign(n1, v1), .Assign(n2, v2)):
		return n1 == n2 && v1 == v2
	case let (.Variable(n1), .Variable(n2)):
		return n1 == n2
	case let (.Literal(l1), .Literal(l2)):
		return l1 == l2
	case let (.Group(n1, v1), .Group(n2, v2)):
		return n1 == n2 && v1 == v2
	default:
		return false
	}
}


func cata<T>(f: Syntax<T> -> T)(_ term: Fix) -> T {
	return (Fix.out >>> { $0.map(cata(f)) } >>> f)(term)
}
