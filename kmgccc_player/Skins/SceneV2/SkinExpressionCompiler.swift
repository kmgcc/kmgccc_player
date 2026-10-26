import Foundation

/// Per-evaluation inputs. `locals` holds node-scoped names: `item`, `index`, `count`,
/// `self`, `parent`, `gesture` and the props of an author template.
struct SkinEvaluationContext {
    let data: SkinSceneData
    var locals: [String: SkinValue] = [:]
    /// The display frame being drawn, in reference-date seconds. Change-tier nodes use the
    /// time they were evaluated; frame-tier nodes use their timeline's frame date.
    var now: Double = Date.timeIntervalSinceReferenceDate
    /// Size-derived facts of the frame being drawn; the feeds only catch up after the update.
    var live: SkinLiveViewport?

    func local(_ name: String) -> SkinValue { locals[name] ?? .null }
    var time: Double { data.time(at: now) }
}

typealias SkinEvaluator = @MainActor (SkinEvaluationContext) -> SkinValue

/// A checked expression. Equality uses the source text: two identical expressions in the same
/// scope always evaluate the same way.
struct SkinCompiledExpression: Equatable {
    let source: String
    let type: SkinValueType
    let tier: SkinDataTier
    let domains: Set<SkinDataDomain>
    let capabilities: Set<String>
    let evaluate: SkinEvaluator

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.source == rhs.source }

    static func constant(_ value: SkinValue) -> Self {
        Self(source: "#\(value.textValue)", type: value.type, tier: .constant, domains: [], capabilities: [], evaluate: { _ in value })
    }

    /// Constant expressions are folded at compile time, so reading one is free.
    var constantValue: SkinValue? {
        guard tier == .constant, domains.isEmpty else { return nil }
        return evaluate(SkinEvaluationContext(data: .placeholder))
    }
}

/// What the compiler may resolve at a given position in the document.
struct SkinCompileEnvironment {
    var params: [String: SkinValueType] = [:]
    var state: [String: SkinValueType] = [:]
    var props: [String: SkinCompiledExpression] = [:]
    /// Node-scoped namespaces available here (`item` only inside `repeat`, `gesture` only in actions).
    var locals: Set<String> = ["self", "parent"]
    var hostCapabilities: Set<String> = []
}

enum SkinExpressionCompiler {
    /// Strings that start with `=` are expressions; everything else is a literal.
    static func compile(_ raw: SkinParameterValue, expected: SkinValueType, environment: SkinCompileEnvironment) throws -> SkinCompiledExpression {
        if case .text(let text) = raw, text.hasPrefix("=") {
            return try compile(source: String(text.dropFirst()), expected: expected, environment: environment)
        }
        let value = literal(raw, expected: expected)
        guard value.type.conforms(to: expected) else {
            throw SkinExpressionError(message: "需要\(expected.displayName)，这里是\(value.type.displayName)", offset: 0)
        }
        return .constant(value)
    }

    static func compile(source: String, expected: SkinValueType, environment: SkinCompileEnvironment) throws -> SkinCompiledExpression {
        let expression = try SkinExpressionParser.parse(source)
        let node = try Compiler(environment: environment).compile(expression)
        guard node.type.conforms(to: expected) else {
            throw SkinExpressionError(message: "结果是\(node.type.displayName)，这里需要\(expected.displayName)", offset: 0)
        }
        if node.tier == .constant, !node.domains.contains(.local) {
            // Fold once; a constant expression never needs to run again.
            let value = node.evaluate(SkinEvaluationContext(data: SkinSceneData.placeholder))
            return SkinCompiledExpression(source: source, type: value.type, tier: .constant, domains: [], capabilities: node.capabilities, evaluate: { _ in value })
        }
        return SkinCompiledExpression(source: source, type: node.type, tier: node.tier, domains: node.domains, capabilities: node.capabilities, evaluate: node.evaluate)
    }

    /// JSON literals become typed values. A colour may be written as a hex string.
    static func literal(_ raw: SkinParameterValue, expected: SkinValueType) -> SkinValue {
        let value = SkinValue(raw)
        if expected == .color, case .text(let text) = value, let color = OKLCHColor(named: text) { return .color(color) }
        return value
    }
}

private struct CompiledNode {
    let type: SkinValueType
    let tier: SkinDataTier
    let domains: Set<SkinDataDomain>
    let capabilities: Set<String>
    let evaluate: SkinEvaluator

    static func constant(_ value: SkinValue) -> Self {
        Self(type: value.type, tier: .constant, domains: [], capabilities: [], evaluate: { _ in value })
    }
}

private struct Compiler {
    let environment: SkinCompileEnvironment

    func compile(_ expression: SkinExpr) throws -> CompiledNode {
        switch expression {
        case .literal(let value):
            return .constant(value)
        case .list(let items):
            let nodes = try items.map { try compile($0) }
            let evaluators = nodes.map(\.evaluate)
            return merge(nodes, type: .list) { context in .list(evaluators.map { $0(context) }) }
        case .path(let components):
            return try path(components)
        case .member(let base, let name):
            let node = try compile(base)
            let evaluate = node.evaluate
            return CompiledNode(type: .any, tier: node.tier, domains: node.domains, capabilities: node.capabilities) { context in
                evaluate(context)[member: name]
            }
        case .index(let base, let index):
            let baseNode = try compile(base)
            let indexNode = try compile(index)
            let baseEvaluate = baseNode.evaluate, indexEvaluate = indexNode.evaluate
            return merge([baseNode, indexNode], type: .any) { context in
                let container = baseEvaluate(context)
                let key = indexEvaluate(context)
                if case .text(let name) = key, case .record = container { return container[member: name] }
                return container[index: SkinValue.number(key.number().rounded(.down)).integer()]
            }
        case .unary(let operation, let operand):
            let node = try compile(operand)
            let evaluate = node.evaluate
            switch operation {
            case .negate:
                guard node.type.conforms(to: .number) else { throw typeError("“-”需要数字") }
                return merge([node], type: .number) { .number(-evaluate($0).number()) }
            case .not:
                return merge([node], type: .boolean) { .boolean(!evaluate($0).isTruthy) }
            }
        case .binary(let operation, let lhs, let rhs):
            return try binary(operation, try compile(lhs), try compile(rhs))
        case .conditional(let condition, let whenTrue, let whenFalse):
            let c = try compile(condition), t = try compile(whenTrue), f = try compile(whenFalse)
            let ce = c.evaluate, te = t.evaluate, fe = f.evaluate
            let type: SkinValueType = t.type == f.type ? t.type : (t.type == .null ? f.type : (f.type == .null ? t.type : .any))
            return merge([c, t, f], type: type) { context in ce(context).isTruthy ? te(context) : fe(context) }
        case .call(let name, let arguments):
            return try call(name, arguments.map { try compile($0) })
        }
    }

    private func merge(_ nodes: [CompiledNode], type: SkinValueType, evaluate: @escaping SkinEvaluator) -> CompiledNode {
        CompiledNode(
            type: type,
            tier: nodes.map(\.tier).max() ?? .constant,
            domains: nodes.reduce(into: Set<SkinDataDomain>()) { $0.formUnion($1.domains) },
            capabilities: nodes.reduce(into: Set<String>()) { $0.formUnion($1.capabilities) },
            evaluate: evaluate
        )
    }

    private func typeError(_ message: String) -> SkinExpressionError { SkinExpressionError(message: message, offset: 0) }

    private func path(_ components: [String]) throws -> CompiledNode {
        let head = components[0]
        let remainder = Array(components.dropFirst())
        func applying(_ node: CompiledNode, _ members: [String]) -> CompiledNode {
            guard !members.isEmpty else { return node }
            let evaluate = node.evaluate
            return CompiledNode(type: .any, tier: node.tier, domains: node.domains, capabilities: node.capabilities) { context in
                members.reduce(evaluate(context)) { $0[member: $1] }
            }
        }

        switch head {
        case "props":
            guard let name = remainder.first else { throw typeError("props 后需要参数名") }
            guard let prop = environment.props[name] else { throw typeError("组件没有声明参数“\(name)”") }
            let node = CompiledNode(type: prop.type, tier: prop.tier, domains: prop.domains, capabilities: prop.capabilities, evaluate: prop.evaluate)
            return applying(node, Array(remainder.dropFirst()))
        case "params":
            guard let name = remainder.first else { throw typeError("params 后需要参数 ID") }
            guard let type = environment.params[name] else { throw typeError("皮肤没有声明参数“\(name)”") }
            let node = CompiledNode(type: type, tier: .change, domains: [.params], capabilities: ["params@1"]) { context in
                context.data.parameter(name)
            }
            return applying(node, Array(remainder.dropFirst()))
        case "state":
            guard let name = remainder.first else { throw typeError("state 后需要状态名") }
            guard let type = environment.state[name] else { throw typeError("场景没有声明状态“\(name)”") }
            let node = CompiledNode(type: type, tier: .change, domains: [.state], capabilities: ["state@1"]) { context in
                context.data.stateValue(name)
            }
            return applying(node, Array(remainder.dropFirst()))
        case "item", "index", "count", "self", "parent", "gesture", "glyph":
            guard environment.locals.contains(head) else {
                throw typeError("“\(head)”只能在\(Self.localScopeDescription(head))中使用")
            }
            let type: SkinValueType = head == "index" || head == "count" ? .number : .any
            // Node-scoped values change with interaction and geometry, never per frame by themselves.
            let node = CompiledNode(type: type, tier: .change, domains: [.local], capabilities: []) { context in
                context.local(head)
            }
            return applying(node, remainder)
        default:
            guard let (field, members) = SkinDataSchema.field(for: components) else {
                let joined = components.joined(separator: ".")
                let hint = SkinDataSchema.suggestion(for: joined).map { "，是否指 \($0)？" } ?? ""
                throw typeError("未知数据“\(joined)”\(hint)")
            }
            let key = components.prefix(components.count - members.count).joined(separator: ".")
            let domain = field.domain
            let sized = domain == .viewport || domain == .host
            let node = CompiledNode(type: field.type, tier: field.tier, domains: [domain], capabilities: [field.capability]) { context in
                (sized ? context.live?.facts[key] : nil) ?? context.data.value(forKey: key, domain: domain, now: context.now)
            }
            return applying(node, members)
        }
    }

    private static func localScopeDescription(_ name: String) -> String {
        switch name {
        case "item", "index", "count": return " repeat 的子节点"
        case "gesture": return "手势操作"
        case "glyph": return " glyphMotion "
        default: return "节点属性"
        }
    }

    private func binary(_ operation: SkinBinaryOperator, _ lhs: CompiledNode, _ rhs: CompiledNode) throws -> CompiledNode {
        let l = lhs.evaluate, r = rhs.evaluate
        switch operation {
        case .add:
            if lhs.type == .text || rhs.type == .text {
                return merge([lhs, rhs], type: .text) { .text(l($0).textValue + r($0).textValue) }
            }
            if lhs.type == .any || rhs.type == .any {
                return merge([lhs, rhs], type: .any) { context in
                    let a = l(context), b = r(context)
                    if case .text = a { return .text(a.textValue + b.textValue) }
                    if case .text = b { return .text(a.textValue + b.textValue) }
                    return .number(a.number() + b.number())
                }
            }
            guard lhs.type.conforms(to: .number), rhs.type.conforms(to: .number) else { throw typeError("“+”需要数字或文字") }
            return merge([lhs, rhs], type: .number) { .number(l($0).number() + r($0).number()) }
        case .subtract, .multiply, .divide, .remainder:
            guard lhs.type.conforms(to: .number), rhs.type.conforms(to: .number) else {
                throw typeError("“\(operation.rawValue)”需要数字")
            }
            return merge([lhs, rhs], type: .number) { context in
                let a = l(context).number(), b = r(context).number()
                switch operation {
                case .subtract: return .number(a - b)
                case .multiply: return .number(a * b)
                case .divide: return .number(b == 0 ? 0 : a / b)
                default: return .number(b == 0 ? 0 : a.truncatingRemainder(dividingBy: b))
                }
            }
        case .equal, .notEqual:
            return merge([lhs, rhs], type: .boolean) { context in
                let equal = Self.looseEqual(l(context), r(context))
                return .boolean(operation == .equal ? equal : !equal)
            }
        case .less, .lessOrEqual, .greater, .greaterOrEqual:
            return merge([lhs, rhs], type: .boolean) { context in
                let a = l(context), b = r(context)
                let ordering: ComparisonResult
                if case .text(let x) = a, case .text(let y) = b { ordering = x.compare(y) }
                else {
                    let x = a.number(), y = b.number()
                    ordering = x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
                }
                switch operation {
                case .less: return .boolean(ordering == .orderedAscending)
                case .lessOrEqual: return .boolean(ordering != .orderedDescending)
                case .greater: return .boolean(ordering == .orderedDescending)
                default: return .boolean(ordering != .orderedAscending)
                }
            }
        case .and:
            return merge([lhs, rhs], type: .boolean) { .boolean(l($0).isTruthy && r($0).isTruthy) }
        case .or:
            return merge([lhs, rhs], type: .boolean) { .boolean(l($0).isTruthy || r($0).isTruthy) }
        case .coalesce:
            let type = lhs.type == rhs.type ? lhs.type : .any
            return merge([lhs, rhs], type: type) { context in
                let value = l(context)
                if case .null = value { return r(context) }
                return value
            }
        }
    }

    static func looseEqual(_ a: SkinValue, _ b: SkinValue) -> Bool {
        switch (a, b) {
        case (.number, .boolean), (.boolean, .number), (.number, .number): return a.number() == b.number()
        case (.color(let x), .color(let y)): return x.hexString == y.hexString
        default: return a == b
        }
    }

    private func call(_ name: String, _ arguments: [CompiledNode]) throws -> CompiledNode {
        guard let function = SkinFunctions.table[name] else {
            let hint = SkinFunctions.table.keys.min { levenshtein($0, name) < levenshtein($1, name) }.map { "，是否指 \($0)()？" } ?? ""
            throw typeError("未知函数“\(name)”\(hint)")
        }
        guard function.arity.contains(arguments.count) else {
            throw typeError("\(name)() 需要 \(function.arityDescription) 个参数，这里有 \(arguments.count) 个")
        }
        for (position, argument) in arguments.enumerated() {
            let expected = function.argumentType(position)
            guard argument.type.conforms(to: expected) else {
                throw typeError("\(name)() 的第 \(position + 1) 个参数需要\(expected.displayName)")
            }
        }
        let evaluators = arguments.map(\.evaluate)
        let implementation = function.implementation
        let base = merge(arguments, type: function.resultType(arguments.map(\.type))) { context in
            implementation(evaluators.map { $0(context) }, context)
        }
        return CompiledNode(
            type: base.type,
            tier: max(base.tier, function.tier),
            domains: base.domains.union(function.domains),
            capabilities: base.capabilities.union(function.capabilities),
            evaluate: base.evaluate
        )
    }
}

/// "，是否指 x？" for the closest candidate within a small edit distance, otherwise empty.
func skinSuggestion(_ name: String, in candidates: some Sequence<String>) -> String {
    guard let best = candidates.min(by: { levenshtein($0, name) < levenshtein($1, name) }),
          levenshtein(best, name) <= max(2, name.count / 3) else { return "" }
    return "，是否指 \(best)？"
}

private func levenshtein(_ lhs: String, _ rhs: String) -> Int {
    let a = Array(lhs), b = Array(rhs)
    guard !a.isEmpty else { return b.count }
    guard !b.isEmpty else { return a.count }
    var previous = Array(0...b.count)
    for (i, left) in a.enumerated() {
        var current = [i + 1]
        for (j, right) in b.enumerated() {
            current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1)))
        }
        previous = current
    }
    return previous[b.count]
}

extension SkinValueType {
    var displayName: String {
        switch self {
        case .any: "任意值"
        case .null: "空值"
        case .boolean: "开关值"
        case .number: "数字"
        case .text: "文字"
        case .color: "颜色"
        case .list: "列表"
        case .record: "记录"
        }
    }
}
