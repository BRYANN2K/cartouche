import Foundation

// Cartouche's own shader presets for Look: a CRT with scanlines and a soft
// vignette, an LCD with its pixel grid. Each comes as slang, which the Metal
// and Vulkan drivers run, and as GLSL for the OpenGL driver. Written under
// Cartouche's RetroArch folder; Original turns the shader off.
public enum Looks {

    public enum Language: String, Sendable, CaseIterable {
        case slang, glsl

        var presetExtension: String { self == .slang ? "slangp" : "glslp" }
    }

    public static func preset(_ look: ConsoleLook, _ language: Language, in paths: RetroArchPaths) -> URL? {
        guard look != .original else { return nil }
        return paths.shaders.appending(path: "\(look.rawValue).\(language.presetExtension)")
    }

    // Written before each launch, so an update of Cartouche brings its shaders
    public static func install(in paths: RetroArchPaths) throws {
        try FileManager.default.createDirectory(at: paths.shaders, withIntermediateDirectories: true)
        for (name, body) in [("crt", crtBody), ("lcd", lcdBody)] {
            try write(slang(body), to: paths.shaders.appending(path: "\(name).slang"))
            try write(preset("\(name).slang"), to: paths.shaders.appending(path: "\(name).slangp"))
            try write(glsl(body), to: paths.shaders.appending(path: "\(name).glsl"))
            try write(preset("\(name).glsl"), to: paths.shaders.appending(path: "\(name).glslp"))
        }
    }

    private static func write(_ text: String, to url: URL) throws {
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    static func preset(_ shader: String) -> String {
        """
        shaders = 1
        shader0 = \(shader)
        filter_linear0 = false
        scale_type0 = viewport
        """ + "\n"
    }

    // The colour change, the same in both languages: colour, coordinate in the
    // picture (0 to 1) and the source size in pixels come in
    static let crtBody = """
        float line = fract(coord.y * size.y);
        float scan = 0.55 + 0.45 * sin(line * 3.14159265);
        vec2 centre = coord - vec2(0.5);
        float vignette = 1.0 - dot(centre, centre) * 0.7;
        colour = colour * scan * vignette * 1.15;
    """

    static let lcdBody = """
        vec2 cell = fract(coord * size);
        float grid = step(0.15, cell.x) * step(0.15, cell.y);
        colour = colour * mix(0.72, 1.0, grid);
    """

    static func slang(_ body: String) -> String {
        """
        #version 450
        // Written by Cartouche for its Look choice

        layout(push_constant) uniform Push
        {
            vec4 SourceSize;
            vec4 OutputSize;
        } params;

        layout(std140, set = 0, binding = 0) uniform UBO
        {
            mat4 MVP;
        } global;

        #pragma stage vertex
        layout(location = 0) in vec4 Position;
        layout(location = 1) in vec2 TexCoord;
        layout(location = 0) out vec2 vTexCoord;

        void main()
        {
            gl_Position = global.MVP * Position;
            vTexCoord = TexCoord;
        }

        #pragma stage fragment
        layout(location = 0) in vec2 vTexCoord;
        layout(location = 0) out vec4 FragColor;
        layout(set = 0, binding = 2) uniform sampler2D Source;

        void main()
        {
            vec2 coord = vTexCoord;
            vec2 size = params.SourceSize.xy;
            vec3 colour = texture(Source, coord).rgb;
        \(body)
            FragColor = vec4(colour, 1.0);
        }
        """ + "\n"
    }

    static func glsl(_ body: String) -> String {
        """
        // Written by Cartouche for its Look choice
        #if defined(VERTEX)
        #if __VERSION__ >= 130
        #define COMPAT_VARYING out
        #define COMPAT_ATTRIBUTE in
        #else
        #define COMPAT_VARYING varying
        #define COMPAT_ATTRIBUTE attribute
        #endif
        COMPAT_ATTRIBUTE vec4 VertexCoord;
        COMPAT_ATTRIBUTE vec4 TexCoord;
        COMPAT_VARYING vec4 TEX0;
        uniform mat4 MVPMatrix;
        void main()
        {
            gl_Position = MVPMatrix * VertexCoord;
            TEX0 = TexCoord;
        }
        #elif defined(FRAGMENT)
        #if __VERSION__ >= 130
        #define COMPAT_VARYING in
        #define COMPAT_TEXTURE texture
        out vec4 FragColor;
        #else
        #define COMPAT_VARYING varying
        #define FragColor gl_FragColor
        #define COMPAT_TEXTURE texture2D
        #endif
        #ifdef GL_ES
        precision mediump float;
        #endif
        uniform sampler2D Texture;
        uniform vec2 TextureSize;
        uniform vec2 InputSize;
        COMPAT_VARYING vec4 TEX0;
        void main()
        {
            vec2 coord = TEX0.xy * TextureSize / InputSize;
            vec2 size = InputSize;
            vec3 colour = COMPAT_TEXTURE(Texture, TEX0.xy).rgb;
        \(body)
            FragColor = vec4(colour, 1.0);
        }
        #endif
        """ + "\n"
    }
}
