'use strict';
StrataModel.start = function(options) {
    const canvas = document.querySelector('canvas'), summary = document.querySelector('output');
    canvas.setAttribute('aria-label', options.format);
    let closed = false, scheduled = false, rotationX = -0.55, rotationY = 0.65, zoom = 0.5;
    let gl, buffer, program, resize;
    function close() {
        closed = true;
        resize?.disconnect();
        if (gl && buffer) gl.deleteBuffer(buffer);
        if (gl && program) gl.deleteProgram(program);
    }
    function unavailable(error) {
        if (closed) return;
        close();
        document.body.replaceChildren(Object.assign(document.createElement('p'), {
            textContent: error?.message === 'limit' ? options.large : options.unavailable
        }));
        StrataModel.failure = String(error?.message ?? 'gpu').slice(0, 120);
        StrataModel.status = 'failed';
    }
    function shader(type, source) {
        const shader = gl.createShader(type);
        if (!shader) throw new Error('gpu');
        gl.shaderSource(shader, source); gl.compileShader(shader);
        if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) { gl.deleteShader(shader); throw new Error('gpu'); }
        return shader;
    }
    function draw() {
        scheduled = false;
        if (closed) return;
        const scale = Math.min(2, window.devicePixelRatio || 1);
        canvas.width = Math.max(1, Math.min(2048, Math.round(canvas.clientWidth * scale)));
        canvas.height = Math.max(1, Math.min(2048, Math.round(canvas.clientHeight * scale)));
        gl.viewport(0, 0, canvas.width, canvas.height);
        gl.clearColor(...options.background, 1); gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
        gl.uniform4f(gl.getUniformLocation(program, 'rotation'), Math.cos(rotationX), Math.sin(rotationX), Math.cos(rotationY), Math.sin(rotationY));
        const aspect = canvas.width / canvas.height;
        gl.uniform2f(gl.getUniformLocation(program, 'scale'), zoom / Math.max(1, aspect), zoom * Math.min(1, aspect));
        gl.uniform3fv(gl.getUniformLocation(program, 'color'), options.color);
        gl.drawArrays(gl.TRIANGLES, 0, StrataModel.info.triangles * 3);
        if (gl.getError() !== gl.NO_ERROR) unavailable(new Error('gpu'));
    }
    function redraw() { if (!closed && !scheduled) { scheduled = true; requestAnimationFrame(draw); } }
    StrataModel.reset = () => { rotationX = -0.55; rotationY = 0.65; zoom = 0.5; redraw(); };
    StrataModel.theme = (background, color, foreground) => {
        options.background = background; options.color = color;
        document.body.style.background = `rgb(${background.map(v => v * 255).join(',')})`;
        document.body.style.color = `rgb(${foreground.map(v => v * 255).join(',')})`;
        redraw();
    };
    function setupProgram() {
        const vertex = shader(gl.VERTEX_SHADER, `
            attribute vec3 position; attribute vec3 normal;
            uniform vec4 rotation; uniform vec2 scale; varying mediump float light;
            vec3 turn(vec3 p) {
                vec3 a = vec3(p.x, rotation.x*p.y-rotation.y*p.z, rotation.y*p.y+rotation.x*p.z);
                return vec3(rotation.z*a.x+rotation.w*a.z, a.y, -rotation.w*a.x+rotation.z*a.z);
            }
            void main() {
                vec3 p = turn(position);
                gl_Position = vec4(p.xy*scale, p.z*0.25, 1.0);
                light = 0.3 + 0.7*abs(dot(turn(normal), normalize(vec3(0.4, 0.7, 1.0))));
            }`);
        const fragment = shader(gl.FRAGMENT_SHADER, 'precision mediump float; uniform vec3 color; varying mediump float light; void main() { gl_FragColor = vec4(color*light, 1.0); }');
        program = gl.createProgram();
        if (!program) throw new Error('gpu');
        gl.attachShader(program, vertex); gl.attachShader(program, fragment); gl.linkProgram(program);
        gl.deleteShader(vertex); gl.deleteShader(fragment);
        if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error('gpu');
        gl.useProgram(program);
    }
    function uploadMesh(mesh) {
        buffer = gl.createBuffer();
        if (!buffer) throw new Error('gpu');
        gl.bindBuffer(gl.ARRAY_BUFFER, buffer); gl.bufferData(gl.ARRAY_BUFFER, mesh.vertices, gl.STATIC_DRAW);
        mesh.vertices = null;
        for (const [name, offset] of [['position', 0], ['normal', 12]]) {
            const location = gl.getAttribLocation(program, name);
            if (location < 0) throw new Error('gpu');
            gl.enableVertexAttribArray(location); gl.vertexAttribPointer(location, 3, gl.FLOAT, false, 24, offset);
        }
        gl.enable(gl.DEPTH_TEST);
    }
    function showDetails(mesh) {
        const format = new Intl.NumberFormat(undefined, {maximumFractionDigits: 3});
        summary.textContent = options.triangles + ': ' + format.format(mesh.triangles) + ' · ' + options.bounds + ': '
            + mesh.dimensions.map(value => format.format(value)).join(' × ') + (mesh.unit ? ' ' + mesh.unit : '');
        document.querySelector('button').textContent = options.reset;
        document.querySelector('button').onclick = StrataModel.reset;
        document.querySelector('aside').textContent = options.help;
    }
    function connectControls() {
        let dragging = null;
        canvas.onpointerdown = event => {
            if (closed || event.button !== 0) return;
            dragging = [event.clientX, event.clientY];
            try { canvas.setPointerCapture(event.pointerId); } catch (_) { dragging = null; return; }
            canvas.focus();
        };
        canvas.onpointermove = event => {
            if (!dragging || closed) return;
            rotationY = (rotationY + (event.clientX - dragging[0])*0.01) % (2*Math.PI);
            rotationX = (rotationX + (event.clientY - dragging[1])*0.01) % (2*Math.PI);
            dragging = [event.clientX, event.clientY]; redraw();
        };
        canvas.onpointerup = canvas.onpointercancel = () => { dragging = null; };
        canvas.addEventListener('wheel', event => {
            event.preventDefault();
            const delta = event.deltaY * (event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? 300 : 1);
            zoom = Math.max(0.05, Math.min(10, zoom * Math.exp(-Math.max(-200, Math.min(200, delta))*0.002)));
            redraw();
        }, {passive: false});
        canvas.onkeydown = event => {
            if (event.key === 'ArrowLeft') rotationY -= 0.1;
            else if (event.key === 'ArrowRight') rotationY += 0.1;
            else if (event.key === 'ArrowUp') rotationX -= 0.1;
            else if (event.key === 'ArrowDown') rotationX += 0.1;
            else if (event.key === '+' || event.key === '=') zoom = Math.min(10, zoom*1.1);
            else if (event.key === '-') zoom = Math.max(0.05, zoom/1.1);
            else if (event.key === '0') { StrataModel.reset(); return; }
            else return;
            event.preventDefault(); redraw();
        };
        canvas.addEventListener('webglcontextlost', event => { event.preventDefault(); unavailable(new Error('gpu')); });
    }
    try {
        const binary = atob(options.data); options.data = null;
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < bytes.length; i++) bytes[i] = binary.charCodeAt(i);
        const mesh = StrataModel.parse(bytes.buffer);
        StrataModel.info = {triangles: mesh.triangles, dimensions: mesh.dimensions, unit: mesh.unit};
        gl = canvas.getContext('webgl', {alpha: false, antialias: true, powerPreference: 'low-power'});
        if (!gl) throw new Error('gpu');
        setupProgram();
        uploadMesh(mesh);
        showDetails(mesh);
        connectControls();
        window.addEventListener('pagehide', close, {once: true});
        resize = new ResizeObserver(redraw); resize.observe(canvas);
        StrataModel.theme(options.background, options.color, options.foreground);
        StrataModel.status = 'ready';
    } catch (error) { unavailable(error); }
};
