'use strict';
globalThis.StrataModel = (() => {
    const core = 'http://schemas.microsoft.com/3dmanufacturing/core/2015/02';
    const production = 'http://schemas.microsoft.com/3dmanufacturing/production/2015/06';
    const relationshipNamespace = 'http://schemas.openxmlformats.org/package/2006/relationships';
    const modelRelationship = 'http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel';
    const maximumNodes = 600000, maximumDepth = 64, maximumObjects = 4096, maximumInstances = 100000;
    const units = {micron: [0.001, 'µm'], millimeter: [1, 'mm'], centimeter: [10, 'cm'], inch: [25.4, 'in'], foot: [304.8, 'ft'], meter: [1000, 'm']};
    const identity = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0];
    function fail(code = 'invalid') { throw new Error(code); }
    function number(text) {
        if (typeof text !== 'string' || text.length > 64 || !/^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/.test(text)) fail();
        const result = Number(text);
        if (!Number.isFinite(result) || Math.abs(result) > 1e100) fail();
        return result;
    }
    function integer(text, minimum = 0) {
        if (typeof text !== 'string' || !/^\d{1,10}$/.test(text)) fail();
        const result = Number(text);
        if (result < minimum || result > 2147483647) fail();
        return result;
    }
    function path(reference, base = '') {
        if (typeof reference !== 'string' || !reference || reference.length > 4096 || /[\\?#:\x00-\x1f]/.test(reference) || reference.startsWith('//')) fail();
        const parts = reference.startsWith('/') ? [] : base.split('/').slice(0, -1);
        const input = reference.startsWith('/') ? reference.slice(1) : reference;
        for (const encoded of input.split('/')) {
            let part;
            try { part = decodeURIComponent(encoded); } catch (_) { fail(); }
            if (!part || part.length > 255 || /[\/\\\x00-\x1f]/.test(part)) fail();
            if (part === '.') continue;
            if (part === '..') { if (!parts.length) fail(); parts.pop(); }
            else parts.push(part);
        }
        if (!parts.length || parts.length > 16) fail();
        return parts.join('/');
    }
    function children(node, name, namespace = core) {
        return Array.from(node.children).filter(child => child.namespaceURI === namespace && child.localName === name);
    }
    function only(node, name) {
        const found = children(node, name);
        if (found.length !== 1) fail();
        return found[0];
    }
    function transform(node) {
        if (!node.hasAttribute('transform')) return identity.slice();
        const values = node.getAttribute('transform').trim().split(/\s+/);
        if (values.length !== 12) fail();
        return values.map(number);
    }
    function multiply(a, b) {
        const result = new Array(12);
        for (let row = 0; row < 4; row++) for (let column = 0; column < 3; column++) {
            let value = row === 3 ? b[9 + column] : 0;
            for (let k = 0; k < 3; k++) value += a[row * 3 + k] * b[k * 3 + column];
            if (!Number.isFinite(value) || Math.abs(value) > 1e100) fail();
            result[row * 3 + column] = value;
        }
        return result;
    }
    function parse(buffer) {
        if (!(buffer instanceof ArrayBuffer) || buffer.byteLength === 0) fail();
        if (buffer.byteLength > 64 * 1024 * 1024) fail('limit');
        let payload;
        try { payload = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(buffer)); } catch (_) { fail(); }
        if (!payload || typeof payload.parts !== 'object' || !payload.parts || Array.isArray(payload.parts)) fail();
        const parts = new Map(Object.entries(payload.parts));
        if (!parts.size || parts.size > 32) fail('limit');
        let nodes = 0, objects = 0, vertices = 0, triangles = 0;
        function xml(encoded) {
            if (typeof encoded !== 'string' || !encoded) fail();
            if (encoded.length > Math.ceil(16 * 1024 * 1024 / 3) * 4) fail('limit');
            let text;
            try {
                const binary = atob(encoded), bytes = new Uint8Array(binary.length);
                for (let i = 0; i < bytes.length; i++) bytes[i] = binary.charCodeAt(i);
                text = new TextDecoder('utf-8', {fatal: true}).decode(bytes);
            } catch (_) { fail(); }
            if (/<!\s*(?:DOCTYPE|ENTITY)/i.test(text)) fail();
            for (let index = text.indexOf('<'); index !== -1; index = text.indexOf('<', index + 1)) {
                if (++nodes > maximumNodes) fail('limit');
            }
            const document = new DOMParser().parseFromString(text, 'application/xml');
            if (document.getElementsByTagName('parsererror').length) fail();
            const root = document.documentElement;
            let node = root, depth = 1;
            while (node) {
                if (depth > maximumDepth || node.attributes.length > 64) fail('limit');
                if (node.firstElementChild) { node = node.firstElementChild; depth++; continue; }
                while (node !== root && !node.nextElementSibling) { node = node.parentElement; depth--; }
                if (node === root) break;
                node = node.nextElementSibling;
            }
            return document.documentElement;
        }
        const relationships = xml(payload.relationships);
        if (relationships.namespaceURI !== relationshipNamespace || relationships.localName !== 'Relationships') fail();
        const ids = new Set(), targets = [];
        for (const relation of children(relationships, 'Relationship', relationshipNamespace)) {
            const id = relation.getAttribute('Id');
            if (!id || ids.has(id)) fail();
            ids.add(id);
            if (relation.getAttribute('Type') !== modelRelationship) continue;
            if (relation.hasAttribute('TargetMode') && relation.getAttribute('TargetMode') !== 'Internal') fail();
            targets.push(path(relation.getAttribute('Target')));
        }
        if (targets.length !== 1) fail();
        const rootPath = targets[0], models = new Map();
        function reference(node, owner) {
            const target = node.getAttributeNS(production, 'path');
            if (target && owner !== rootPath) fail();
            return {path: target ? path(target, owner) : owner, id: integer(node.getAttribute('objectid'), 1), transform: transform(node)};
        }
        function mesh(node) {
            const positions = children(only(node, 'vertices'), 'vertex');
            const faces = children(only(node, 'triangles'), 'triangle');
            vertices += positions.length; triangles += faces.length;
            if (positions.length < 3 || !faces.length) fail();
            if (vertices > StrataMesh.maximumTriangles * 3 || triangles > StrataMesh.maximumTriangles) fail('limit');
            const points = new Float64Array(positions.length * 3), indexes = new Uint32Array(faces.length * 3);
            positions.forEach((position, index) => ['x', 'y', 'z'].forEach((axis, offset) => {
                points[index * 3 + offset] = number(position.getAttribute(axis));
            }));
            faces.forEach((face, index) => ['v1', 'v2', 'v3'].forEach((attribute, offset) => {
                const value = integer(face.getAttribute(attribute));
                if (value >= positions.length) fail();
                indexes[index * 3 + offset] = value;
            }));
            return {points, indexes};
        }
        function model(location) {
            if (models.has(location)) return models.get(location);
            if (!parts.has(location)) fail();
            const root = xml(parts.get(location));
            if (root.localName !== 'model' || root.namespaceURI !== core) fail();
            for (const prefix of (root.getAttribute('requiredextensions') || '').split(/\s+/).filter(Boolean)) {
                if (root.lookupNamespaceURI(prefix) !== production) fail('unsupported');
            }
            const unit = units[root.getAttribute('unit') || 'millimeter'];
            if (!Array.isArray(unit)) fail();
            const resources = new Map(), resourceIds = new Set();
            for (const resource of only(root, 'resources').children) {
                if (resource.hasAttribute('id')) {
                    const id = integer(resource.getAttribute('id'), 1);
                    if (resourceIds.has(id)) fail();
                    resourceIds.add(id);
                }
                if (resource.namespaceURI !== core || resource.localName !== 'object') continue;
                if (++objects > maximumObjects) fail('limit');
                const id = integer(resource.getAttribute('id'), 1), meshes = children(resource, 'mesh'), components = children(resource, 'components');
                if (meshes.length + components.length !== 1) fail();
                const links = components.length ? children(components[0], 'component') : [];
                if (components.length && !links.length) fail();
                if (links.length > maximumObjects) fail('limit');
                resources.set(id, meshes.length ? {mesh: mesh(meshes[0])} : {components: links.map(node => reference(node, location))});
            }
            const items = children(only(root, 'build'), 'item');
            if (items.length > maximumObjects) fail('limit');
            const result = {unit, resources, build: location === rootPath ? items.map(node => reference(node, location)) : []};
            models.set(location, result);
            return result;
        }
        const root = model(rootPath);
        if (!root.build.length) fail();
        function visitTriangles(visit) {
            let instances = 0;
            const active = new Set();
            function walk(ref, parent, matrix, depth) {
                if (depth > maximumDepth || ++instances > maximumInstances) fail('limit');
                const owner = model(ref.path), object = owner.resources.get(ref.id), key = ref.path + '#' + ref.id;
                if (!object || active.has(key)) fail();
                active.add(key);
                const local = ref.transform.slice(), ratio = owner.unit[0] / parent.unit[0];
                for (let i = 0; i < 9; i++) local[i] *= ratio;
                const combined = multiply(local, matrix);
                if (object.mesh) {
                    const {points, indexes} = object.mesh;
                    for (let face = 0; face < indexes.length; face += 3) {
                        const triangle = [];
                        for (let vertex = 0; vertex < 3; vertex++) {
                            const index = indexes[face + vertex] * 3;
                            for (let axis = 0; axis < 3; axis++) {
                                const value = points[index] * combined[axis] + points[index + 1] * combined[3 + axis]
                                    + points[index + 2] * combined[6 + axis] + combined[9 + axis];
                                if (!Number.isFinite(value) || Math.abs(value) > 1e100) fail();
                                triangle.push(value);
                            }
                        }
                        visit(triangle);
                    }
                } else for (const child of object.components) walk(child, owner, combined, depth + 1);
                active.delete(key);
            }
            for (const item of root.build) walk(item, root, identity, 1);
        }
        const result = StrataMesh.normalize(visitTriangles);
        result.unit = root.unit[1];
        return result;
    }
    return {parse};
})();
