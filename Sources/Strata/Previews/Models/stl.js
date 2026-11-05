'use strict';
globalThis.StrataModel = (() => {
    const maximumBytes = 16 * 1024 * 1024;
    const maximumTriangles = StrataMesh.maximumTriangles;
    const maximumCoordinate = 1e100;
    function fail(code = 'invalid') { throw new Error(code); }
    function number(token) {
        if (!/^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/.test(token)) fail();
        const value = Number(token);
        if (!Number.isFinite(value) || Math.abs(value) > maximumCoordinate) fail();
        return value;
    }
    function ascii(text, visit) {
        let offset = 0, count = 0;
        function token() {
            while (offset < text.length && /\s/.test(text[offset])) offset++;
            const start = offset;
            while (offset < text.length && !/\s/.test(text[offset])) {
                if (offset - start >= 64) fail();
                offset++;
            }
            return text.slice(start, offset);
        }
        function expect(value) { if (token() !== value) fail(); }
        function line() {
            let size = 0;
            while (offset < text.length && text[offset] !== '\n' && text[offset] !== '\r') {
                if (++size > 4096) fail();
                offset++;
            }
        }
        expect('solid'); line();
        while (true) {
            const kind = token();
            if (kind === 'endsolid') {
                line();
                const next = token();
                if (!next) break;
                if (next !== 'solid') fail();
                line(); continue;
            }
            if (kind !== 'facet') fail();
            if (++count > maximumTriangles) fail('limit');
            expect('normal'); for (let i = 0; i < 3; i++) number(token());
            expect('outer'); expect('loop');
            const vertices = [];
            for (let vertex = 0; vertex < 3; vertex++) {
                expect('vertex'); for (let axis = 0; axis < 3; axis++) vertices.push(number(token()));
            }
            expect('endloop'); expect('endfacet');
            visit(vertices);
        }
        if (count === 0) fail();
        return count;
    }
    function parse(buffer) {
        if (!(buffer instanceof ArrayBuffer) || buffer.byteLength === 0) fail();
        if (buffer.byteLength > maximumBytes) fail('limit');
        const view = new DataView(buffer);
        const count = buffer.byteLength >= 84 ? view.getUint32(80, true) : 0;
        const binary = buffer.byteLength >= 84 && 84 + count * 50 === buffer.byteLength;
        if (binary && (count === 0 || count > maximumTriangles)) fail(count ? 'limit' : 'invalid');
        let text = null;
        if (!binary) {
            try { text = new TextDecoder('utf-8', {fatal: true}).decode(buffer); } catch (_) { fail(); }
        }
        function visitTriangles(visit) {
            if (!binary) return ascii(text, visit);
            for (let triangle = 0; triangle < count; triangle++) {
                const points = [];
                for (let index = 0; index < 9; index++) {
                    const value = view.getFloat32(84 + triangle * 50 + 12 + index * 4, true);
                    if (!Number.isFinite(value)) fail();
                    points.push(value);
                }
                visit(points);
            }
            return count;
        }
        return StrataMesh.normalize(visitTriangles);
    }
    return {parse};
})();
