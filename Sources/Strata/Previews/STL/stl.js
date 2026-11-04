'use strict';
globalThis.StrataSTL = (() => {
    const maximumBytes = 16 * 1024 * 1024;
    const maximumTriangles = 250000;
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
        const minimum = [Infinity, Infinity, Infinity], maximum = [-Infinity, -Infinity, -Infinity];
        const triangles = visitTriangles(points => {
            for (let i = 0; i < 9; i++) {
                const axis = i % 3;
                minimum[axis] = Math.min(minimum[axis], points[i]);
                maximum[axis] = Math.max(maximum[axis], points[i]);
            }
        });
        const dimensions = maximum.map((value, axis) => value - minimum[axis]);
        const span = Math.max(...dimensions);
        if (!(span > 0) || !Number.isFinite(span)) fail();
        const center = maximum.map((value, axis) => minimum[axis] + dimensions[axis] / 2);
        const vertices = new Float32Array(triangles * 18);
        let offset = 0;
        visitTriangles(points => {
            const p = points.map((value, i) => (value - center[i % 3]) / span * 2);
            const a = [p[3]-p[0], p[4]-p[1], p[5]-p[2]], b = [p[6]-p[0], p[7]-p[1], p[8]-p[2]];
            const n = [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]];
            const length = Math.hypot(...n);
            const normal = length > 1e-12 ? n.map(value => value / length) : [0, 0, 1];
            for (let vertex = 0; vertex < 3; vertex++) {
                for (let axis = 0; axis < 3; axis++) vertices[offset++] = p[vertex*3 + axis];
                for (const value of normal) vertices[offset++] = value;
            }
        });
        return {triangles, dimensions, vertices};
    }
    return {parse};
})();
