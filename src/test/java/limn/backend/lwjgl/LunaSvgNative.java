package limn.backend.lwjgl;

/**
 * The shim's entry points as limn-toolkit's backend declares them, here only so that this
 * repository can test what it builds: JNI binds a native method by the class it is declared in,
 * and the shim's are named for this class. The toolkit's own copy is the one an application runs;
 * the two must agree, and the ABI number is what says whether they do.
 */
final class LunaSvgNative {

    private LunaSvgNative() {
    }

    static native int abi();

    static native String lunasvgVersion();

    static native long open(byte[] text);

    static native boolean size(long document, float[] out);

    static native boolean setAttribute(long document, byte[] id, byte[] name, byte[] value);

    static native boolean render(long document, int width, int height, byte[] out);

    static native void close(long document);

    static native boolean addFont(byte[] family, boolean bold, boolean italic, byte[] data);
}
