// The JNI face of lunasvg for the Limn toolkit: open a document from bytes, read its size, change
// an attribute of an element by id, draw it into straight RGBA, close it, and register a font.
// Nothing else of lunasvg is reachable from Java, on purpose: what the toolkit does to an SVG
// before it gets here (parsing it again, refusing what it will not draw, removing what it plays
// itself, reading a picture beside it) is the toolkit's, in Java, where it can be fuzzed.
//
// The Java half is limn.backend.lwjgl.LunaSvgNative in limn-toolkit's backend; the two shake
// hands on LIMN_SVG_ABI before anything else is called, and the number moves only when a
// signature below does, here first.
//
// ONE CALL AT A TIME, for the whole process. lunasvg draws text through plutovg, whose font cache
// is guarded by a mutex only where C11 <threads.h> exists or on Windows: on macOS it is not
// guarded at all. Documents are independent, but every one of them reaches that cache, so every
// entry point below takes one lock. A document is drawn in well under a millisecond at the sizes
// a user interface asks for, so the lock costs nothing a frame notices.
//
// NO C++ EXCEPTION LEAVES. An exception crossing a JNI frame is undefined behaviour, and lunasvg
// allocates by what a file says (a bitmap of the size asked for, a path of the points read), so
// std::bad_alloc is a file away. Every entry point catches everything and answers failure.
//
// Strings arrive as UTF-8 byte arrays, not jstrings: JNI hands a jstring out as *modified* UTF-8,
// which is not UTF-8 for a NUL or a character outside the BMP, and an attribute's value is text a
// file chose.

#include <jni.h>
#include <lunasvg.h>

#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>

#define LIMN_SVG_ABI 1

namespace {

std::mutex& lunasvgLock() {
    static std::mutex lock;
    return lock;
}

/** The bytes of a Java array as a std::string, or nothing when the array is null. */
bool utf8(JNIEnv* env, jbyteArray array, std::string& out) {
    if (array == nullptr) {
        return false;
    }
    jsize length = env->GetArrayLength(array);
    out.resize(static_cast<size_t>(length));
    if (length > 0) {
        env->GetByteArrayRegion(array, 0, length, reinterpret_cast<jbyte*>(&out[0]));
    }
    return !env->ExceptionCheck();
}

lunasvg::Document* document(jlong handle) {
    return reinterpret_cast<lunasvg::Document*>(static_cast<intptr_t>(handle));
}

void releaseFontData(void* data) {
    std::free(data);
}

} // namespace

extern "C" {

#define LIMN_SVG(name) Java_limn_backend_lwjgl_LunaSvgNative_##name

/** The version of this interface, which the Java half compares with its own before anything else. */
JNIEXPORT jint JNICALL LIMN_SVG(abi)(JNIEnv*, jclass) {
    return LIMN_SVG_ABI;
}

/** The lunasvg this library was built from, as major.minor.micro. */
JNIEXPORT jstring JNICALL LIMN_SVG(lunasvgVersion)(JNIEnv* env, jclass) {
    return env->NewStringUTF(LUNASVG_VERSION_STRING);
}

/** Opens a document from the text of an SVG; 0 when lunasvg cannot read it. */
JNIEXPORT jlong JNICALL LIMN_SVG(open)(JNIEnv* env, jclass, jbyteArray text) {
    std::string bytes;
    if (!utf8(env, text, bytes)) {
        return 0;
    }
    try {
        std::lock_guard<std::mutex> hold(lunasvgLock());
        std::unique_ptr<lunasvg::Document> opened = lunasvg::Document::loadFromData(bytes.data(), bytes.size());
        return opened ? static_cast<jlong>(reinterpret_cast<intptr_t>(opened.release())) : 0;
    } catch (...) {
        return 0;
    }
}

/** The document's own width and height in pixels, into a two-float array; false if it has none. */
JNIEXPORT jboolean JNICALL LIMN_SVG(size)(JNIEnv* env, jclass, jlong handle, jfloatArray out) {
    lunasvg::Document* doc = document(handle);
    if (doc == nullptr || out == nullptr || env->GetArrayLength(out) < 2) {
        return JNI_FALSE;
    }
    try {
        jfloat size[2];
        {
            std::lock_guard<std::mutex> hold(lunasvgLock());
            size[0] = doc->width();
            size[1] = doc->height();
        }
        env->SetFloatArrayRegion(out, 0, 2, size);
        return env->ExceptionCheck() ? JNI_FALSE : JNI_TRUE;
    } catch (...) {
        return JNI_FALSE;
    }
}

/** Sets an attribute of the element with that id; false if there is no such element. */
JNIEXPORT jboolean JNICALL LIMN_SVG(setAttribute)(JNIEnv* env, jclass, jlong handle, jbyteArray id,
                                                   jbyteArray name, jbyteArray value) {
    lunasvg::Document* doc = document(handle);
    std::string elementId, attribute, text;
    if (doc == nullptr || !utf8(env, id, elementId) || !utf8(env, name, attribute) || !utf8(env, value, text)) {
        return JNI_FALSE;
    }
    try {
        std::lock_guard<std::mutex> hold(lunasvgLock());
        lunasvg::Element element = doc->getElementById(elementId);
        if (element.isNull()) {
            return JNI_FALSE;
        }
        element.setAttribute(attribute, text);
        return JNI_TRUE;
    } catch (...) {
        return JNI_FALSE;
    }
}

/**
 * Draws the document, scaled to width by height, into out as straight-alpha RGBA rows of
 * width * 4 bytes, top row first. False if it could not be drawn or out is too small.
 */
JNIEXPORT jboolean JNICALL LIMN_SVG(render)(JNIEnv* env, jclass, jlong handle, jint width, jint height,
                                             jbyteArray out) {
    lunasvg::Document* doc = document(handle);
    if (doc == nullptr || out == nullptr || width <= 0 || height <= 0) {
        return JNI_FALSE;
    }
    const jlong rowBytes = static_cast<jlong>(width) * 4;
    if (static_cast<jlong>(env->GetArrayLength(out)) < rowBytes * height) {
        return JNI_FALSE;
    }
    try {
        lunasvg::Bitmap bitmap;
        {
            std::lock_guard<std::mutex> hold(lunasvgLock());
            bitmap = doc->renderToBitmap(width, height, 0x00000000);
        }
        if (bitmap.isNull()) {
            return JNI_FALSE;
        }
        bitmap.convertToRGBA();
        const uint8_t* rows = bitmap.data();
        for (jint y = 0; y < height; y++) {
            env->SetByteArrayRegion(out, static_cast<jsize>(y * rowBytes), static_cast<jsize>(rowBytes),
                                    reinterpret_cast<const jbyte*>(rows + static_cast<size_t>(y) * bitmap.stride()));
        }
        return env->ExceptionCheck() ? JNI_FALSE : JNI_TRUE;
    } catch (...) {
        return JNI_FALSE;
    }
}

/** Closes a document; 0 is ignored. */
JNIEXPORT void JNICALL LIMN_SVG(close)(JNIEnv*, jclass, jlong handle) {
    lunasvg::Document* doc = document(handle);
    if (doc == nullptr) {
        return;
    }
    try {
        std::lock_guard<std::mutex> hold(lunasvgLock());
        delete doc;
    } catch (...) {
        // nothing left to answer: the document is gone or leaks, and neither reaches Java
    }
}

/**
 * Registers a font for SVG text under a family name, from the bytes of a TrueType or OpenType
 * file, copied: the Java array may go once this returns.
 */
JNIEXPORT jboolean JNICALL LIMN_SVG(addFont)(JNIEnv* env, jclass, jbyteArray family, jboolean bold,
                                              jboolean italic, jbyteArray data) {
    std::string name, bytes;
    if (!utf8(env, family, name) || !utf8(env, data, bytes) || bytes.empty()) {
        return JNI_FALSE;
    }
    void* copy = std::malloc(bytes.size());
    if (copy == nullptr) {
        return JNI_FALSE;
    }
    std::memcpy(copy, bytes.data(), bytes.size());
    try {
        std::lock_guard<std::mutex> hold(lunasvgLock());
        if (lunasvg_add_font_face_from_data(name.c_str(), bold == JNI_TRUE, italic == JNI_TRUE, copy, bytes.size(),
                                            releaseFontData, copy)) {
            return JNI_TRUE;
        }
    } catch (...) {
    }
    // lunasvg hands the data to its destroy function on failure as well as on success, so the
    // copy is not freed here: freeing it again would be the double free.
    return JNI_FALSE;
}

} // extern "C"
