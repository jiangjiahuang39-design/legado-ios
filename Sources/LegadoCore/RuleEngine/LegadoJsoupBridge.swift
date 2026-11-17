import Foundation
import JavaScriptCore
import SwiftSoup

/// 让书源 JS 里的 `org.jsoup.Jsoup.parse(...)`、`new org.jsoup.nodes.Element('div')`、
/// `new org.jsoup.select.Elements()` 以及 Element/Elements 常用方法可用（底层是 SwiftSoup）。
///
/// JS 侧对象只保存一个整数句柄，真正的节点放在 `HandleTable` 里（随 JSContext 一起释放）。
/// 规则脚本如果返回 Element/Elements，会在 `__legadoJsoupNormalize` 里被转成 outerHtml 字符串（列表），
/// 后续的 CSS/XPath 字段规则再对这些 HTML 片段取值。
enum LegadoJsoupBridge {
    static func install(on java: JSValue?, in context: JSContext) {
        guard let java else { return }
        let table = HandleTable()

        let parse: @convention(block) (String, String) -> Int = { html, base in
            guard let document = try? SwiftSoup.parse(html, base) else { return -1 }
            return table.store(document)
        }
        let make: @convention(block) (String) -> Int = { tag in
            guard let parsedTag = try? Tag.valueOf(tag) else { return -1 }
            return table.store(Element(parsedTag, ""))
        }
        let newList: @convention(block) () -> Int = { table.storeList([]) }

        let select: @convention(block) (Int, String) -> Int = { id, css in
            var found: [Element] = []
            var seen = Set<ObjectIdentifier>()
            for element in table.targets(id) {
                guard let matched = try? element.select(css) else { continue }
                for item in matched.array() where seen.insert(ObjectIdentifier(item)).inserted {
                    found.append(item)
                }
            }
            return table.storeList(found)
        }
        let size: @convention(block) (Int) -> Int = { id in table.targets(id).count }
        let get: @convention(block) (Int, Int) -> Int = { id, index in
            let items = table.targets(id)
            guard index >= 0, index < items.count else { return -1 }
            return table.isList(id) ? table.store(items[index]) : table.store(items[0])
        }
        let add: @convention(block) (Int, Int) -> Void = { listID, elementID in
            guard let element = table.element(elementID) else { return }
            table.append(listID, element)
        }

        let string: @convention(block) (Int, String, String) -> String = { id, operation, argument in
            let items = table.targets(id)
            let isList = table.isList(id)

            func single(_ element: Element) -> String {
                switch operation {
                case "attr":
                    if argument.hasPrefix("abs:") {
                        return (try? element.absUrl(String(argument.dropFirst(4)))) ?? ""
                    }
                    return (try? element.attr(argument)) ?? ""
                case "absUrl": return (try? element.absUrl(argument)) ?? ""
                case "text": return (try? element.text()) ?? ""
                case "html": return (try? element.html()) ?? ""
                case "outerHtml": return (try? element.outerHtml()) ?? ""
                case "tagName": return element.tagName()
                case "ownText": return element.ownText()
                case "id": return element.id()
                case "className": return (try? element.className()) ?? ""
                case "val": return (try? element.val()) ?? ""
                default: return ""
                }
            }

            guard isList else { return items.first.map(single) ?? "" }
            switch operation {
            case "text": return items.map(single).joined(separator: " ")
            case "html", "outerHtml": return items.map(single).joined(separator: "\n")
            case "attr":
                // Elements.attr：取第一个带该属性的元素
                for element in items {
                    let key = argument.hasPrefix("abs:") ? String(argument.dropFirst(4)) : argument
                    if element.hasAttr(key) || argument.hasPrefix("abs:") {
                        let value = single(element)
                        if !value.isEmpty { return value }
                    }
                }
                return ""
            default: return items.first.map(single) ?? ""
            }
        }

        let setter: @convention(block) (Int, String, String, String) -> Void = { id, operation, first, second in
            for element in table.targets(id) {
                switch operation {
                case "attr": _ = try? element.attr(first, second)
                case "text": _ = try? element.text(first)
                case "html": _ = try? element.html(first)
                case "addClass": _ = try? element.addClass(first)
                case "removeAttr": _ = try? element.removeAttr(first)
                default: break
                }
            }
        }

        let has: @convention(block) (Int, String, String) -> Bool = { id, kind, argument in
            guard let element = table.targets(id).first else { return false }
            return kind == "class" ? element.hasClass(argument) : element.hasAttr(argument)
        }

        let tree: @convention(block) (Int, String) -> Int = { id, operation in
            guard let element = table.targets(id).first else { return -1 }
            switch operation {
            case "parent":
                guard let parent = element.parent() else { return -1 }
                return table.store(parent)
            case "children":
                return table.storeList(element.children().array())
            case "next":
                guard let next = (try? element.nextElementSibling()) ?? nil else { return -1 }
                return table.store(next)
            case "prev":
                guard let previous = (try? element.previousElementSibling()) ?? nil else { return -1 }
                return table.store(previous)
            default:
                return -1
            }
        }

        let append: @convention(block) (Int, Int) -> Void = { parentID, childID in
            guard let parent = table.element(parentID), let child = table.element(childID) else { return }
            _ = try? parent.appendChild(child)
        }
        let remove: @convention(block) (Int) -> Void = { id in
            for element in table.targets(id) { _ = try? element.remove() }
        }

        java.setObject(parse, forKeyedSubscript: "__jsoupParse" as NSString)
        java.setObject(make, forKeyedSubscript: "__jsoupMake" as NSString)
        java.setObject(newList, forKeyedSubscript: "__jsoupNewList" as NSString)
        java.setObject(select, forKeyedSubscript: "__jsoupSelect" as NSString)
        java.setObject(size, forKeyedSubscript: "__jsoupSize" as NSString)
        java.setObject(get, forKeyedSubscript: "__jsoupGet" as NSString)
        java.setObject(add, forKeyedSubscript: "__jsoupAdd" as NSString)
        java.setObject(string, forKeyedSubscript: "__jsoupStr" as NSString)
        java.setObject(setter, forKeyedSubscript: "__jsoupSet" as NSString)
        java.setObject(has, forKeyedSubscript: "__jsoupHas" as NSString)
        java.setObject(tree, forKeyedSubscript: "__jsoupTree" as NSString)
        java.setObject(append, forKeyedSubscript: "__jsoupAppend" as NSString)
        java.setObject(remove, forKeyedSubscript: "__jsoupRemove" as NSString)
        context.evaluateScript(bootstrap)
    }

    private final class HandleTable: @unchecked Sendable {
        private var elements: [Int: Element] = [:]
        private var lists: [Int: [Element]] = [:]
        private var counter = 0

        func store(_ element: Element) -> Int {
            counter += 1
            elements[counter] = element
            return counter
        }

        func storeList(_ list: [Element]) -> Int {
            counter += 1
            lists[counter] = list
            return counter
        }

        func element(_ id: Int) -> Element? { elements[id] }
        func isList(_ id: Int) -> Bool { lists[id] != nil }
        func append(_ id: Int, _ element: Element) { lists[id, default: []].append(element) }

        /// 单个元素返回 [元素]；列表返回全部；无效句柄返回空。
        func targets(_ id: Int) -> [Element] {
            if let element = elements[id] { return [element] }
            return lists[id] ?? []
        }
    }

    private static let bootstrap = #"""
    (function (global) {
      var P = java.__jsoupParse, MK = java.__jsoupMake, NL = java.__jsoupNewList, SEL = java.__jsoupSelect,
          SZ = java.__jsoupSize, GET = java.__jsoupGet, ADD = java.__jsoupAdd, STR = java.__jsoupStr,
          SET = java.__jsoupSet, HAS = java.__jsoupHas, TREE = java.__jsoupTree,
          APP = java.__jsoupAppend, RM = java.__jsoupRemove;
      var ElProto = {}, ElsProto = {};
      function handle(o, h) { Object.defineProperty(o, '__h', { value: h }); return o; }
      function wrapEl(h) { return h < 0 ? null : handle(Object.create(ElProto), h); }
      function wrapEls(h) { return handle(Object.create(ElsProto), h); }
      function JElement(tag) {
        if (!(this instanceof JElement)) return new JElement(tag);
        var h = MK(String(tag));
        if (h < 0) throw new Error('Invalid tag name: ' + tag);
        handle(this, h);
      }
      JElement.prototype = ElProto;
      function JElements() {
        if (!(this instanceof JElements)) return new JElements();
        handle(this, NL());
      }
      JElements.prototype = ElsProto;
      function def(proto, name, fn) {
        Object.defineProperty(proto, name, { value: fn, writable: true, configurable: true });
      }

      // ---- 两者共有 ----
      [ElProto, ElsProto].forEach(function (proto) {
        ['tagName', 'ownText', 'id', 'className', 'val', 'outerHtml'].forEach(function (name) {
          def(proto, name, function () { return STR(this.__h, name, ''); });
        });
        def(proto, 'text', function (v) {
          if (arguments.length > 0) { SET(this.__h, 'text', String(v), ''); return this; }
          return STR(this.__h, 'text', '');
        });
        def(proto, 'html', function (v) {
          if (arguments.length > 0) { SET(this.__h, 'html', String(v), ''); return this; }
          return STR(this.__h, 'html', '');
        });
        def(proto, 'attr', function (k, v) {
          if (arguments.length > 1) { SET(this.__h, 'attr', String(k), String(v)); return this; }
          return STR(this.__h, 'attr', String(k));
        });
        def(proto, 'absUrl', function (k) { return STR(this.__h, 'absUrl', String(k)); });
        def(proto, 'hasClass', function (c) { return HAS(this.__h, 'class', String(c)); });
        def(proto, 'hasAttr', function (k) { return HAS(this.__h, 'attr', String(k)); });
        def(proto, 'addClass', function (c) { SET(this.__h, 'addClass', String(c), ''); return this; });
        def(proto, 'removeAttr', function (k) { SET(this.__h, 'removeAttr', String(k), ''); return this; });
        def(proto, 'select', function (css) { return wrapEls(SEL(this.__h, String(css))); });
        def(proto, 'selectFirst', function (css) { return wrapEl(GET(SEL(this.__h, String(css)), 0)); });
        def(proto, 'getElementsByTag', function (t) { return wrapEls(SEL(this.__h, String(t))); });
        def(proto, 'getElementsByClass', function (c) { return wrapEls(SEL(this.__h, '.' + String(c))); });
        def(proto, 'getElementById', function (i) { return wrapEl(GET(SEL(this.__h, '#' + String(i)), 0)); });
        def(proto, 'remove', function () { RM(this.__h); return this; });
        def(proto, 'toString', function () { return STR(this.__h, 'outerHtml', ''); });
      });

      // ---- Element ----
      def(ElProto, 'parent', function () { return wrapEl(TREE(this.__h, 'parent')); });
      def(ElProto, 'children', function () { return wrapEls(TREE(this.__h, 'children')); });
      def(ElProto, 'child', function (i) { return wrapEl(GET(TREE(this.__h, 'children'), i)); });
      def(ElProto, 'nextElementSibling', function () { return wrapEl(TREE(this.__h, 'next')); });
      def(ElProto, 'previousElementSibling', function () { return wrapEl(TREE(this.__h, 'prev')); });
      def(ElProto, 'appendChild', function (c) { APP(this.__h, c.__h); return this; });
      def(ElProto, 'body', function () { return wrapEl(GET(SEL(this.__h, 'body'), 0)); });
      def(ElProto, 'head', function () { return wrapEl(GET(SEL(this.__h, 'head'), 0)); });

      // ---- Elements（按 Java List 的用法：size/get/first/last/add）----
      def(ElsProto, 'size', function () { return SZ(this.__h); });
      def(ElsProto, 'isEmpty', function () { return SZ(this.__h) === 0; });
      def(ElsProto, 'get', function (i) { return wrapEl(GET(this.__h, Number(i))); });
      def(ElsProto, 'eq', function (i) { return wrapEl(GET(this.__h, Number(i))); });
      def(ElsProto, 'first', function () { return wrapEl(GET(this.__h, 0)); });
      def(ElsProto, 'last', function () { var n = SZ(this.__h); return n ? wrapEl(GET(this.__h, n - 1)) : null; });
      def(ElsProto, 'add', function (e) { ADD(this.__h, e.__h); return true; });
      def(ElsProto, 'toArray', function () {
        var out = [], n = SZ(this.__h);
        for (var i = 0; i < n; i++) out.push(wrapEl(GET(this.__h, i)));
        return out;
      });
      def(ElsProto, 'eachText', function () {
        var out = [], n = SZ(this.__h);
        for (var i = 0; i < n; i++) out.push(STR(GET(this.__h, i), 'text', ''));
        return out;
      });
      def(ElsProto, 'eachAttr', function (k) {
        var out = [], n = SZ(this.__h);
        for (var i = 0; i < n; i++) { var v = STR(GET(this.__h, i), 'attr', String(k)); if (v) out.push(v); }
        return out;
      });

      var Jsoup = {
        parse: function (html, base) { return wrapEl(P(html == null ? '' : String(html), base == null ? '' : String(base))); }
      };
      Jsoup.parseBodyFragment = Jsoup.parse;
      global.org = {
        jsoup: {
          Jsoup: Jsoup,
          nodes: { Element: JElement, Document: JElement },
          select: { Elements: JElements }
        }
      };

      // 规则脚本返回 Element/Elements 时转成 HTML 字符串（列表），让后续字段规则继续解析。
      global.__legadoJsoupNormalize = function (value) {
        function convert(x) {
          if (x instanceof JElement) return STR(x.__h, 'outerHtml', '');
          if (x instanceof JElements) {
            var out = [], n = SZ(x.__h);
            for (var i = 0; i < n; i++) out.push(STR(GET(x.__h, i), 'outerHtml', ''));
            return out;
          }
          return x;
        }
        if (value instanceof JElement || value instanceof JElements) return convert(value);
        if (Array.isArray(value)) {
          return value.map(function (item) {
            var c = convert(item);
            return Array.isArray(c) ? c.join('') : c;
          });
        }
        return value;
      };
    })(this);
    """#
}
