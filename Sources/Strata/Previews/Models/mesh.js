'use strict';
globalThis.StrataMesh = (() => {
    const maximumTriangles = 250000;
    function normalize(visitTriangles) {
        const minimum = [Infinity, Infinity, Infinity], maximum = [-Infinity, -Infinity, -Infinity];
        let triangles = 0;
        visitTriangles(points => {
            if (++triangles > maximumTriangles) throw new Error('limit');
            if (points.length !== 9 || !points.every(Number.isFinite)) throw new Error('invalid');
            for (let i = 0; i < 9; i++) {
                const axis = i % 3;
                minimum[axis] = Math.min(minimum[axis], points[i]);
                maximum[axis] = Math.max(maximum[axis], points[i]);
            }
        });
        const dimensions = maximum.map((value, axis) => value - minimum[axis]);
        const span = Math.max(...dimensions);
        if (!(span > 0) || !Number.isFinite(span)) throw new Error('invalid');
        const center = maximum.map((value, axis) => minimum[axis] + dimensions[axis] / 2);
        const vertices = new Float32Array(triangles * 18);
        let offset = 0;
        visitTriangles(points => {
            if (offset + 18 > vertices.length) throw new Error('invalid');
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
        if (offset !== vertices.length) throw new Error('invalid');
        return {triangles, dimensions, vertices};
    }
    return {maximumTriangles, normalize};
})();
