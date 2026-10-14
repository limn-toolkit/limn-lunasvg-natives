package limn.backend.lwjgl;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * What the library built for this machine does through each entry point: the handshake, a
 * document opened, measured, changed and drawn, a damaged one refused, and many drawn at once.
 * Skipped with a sentence when scripts/build-lunasvg.sh has not been run here.
 */
class LunaSvgNativeTest {

    @BeforeAll
    static void load() {
        String os = System.getProperty("os.name").toLowerCase(Locale.ROOT);
        String arch = System.getProperty("os.arch").toLowerCase(Locale.ROOT);
        String platform = (os.contains("mac") ? "macos" : os.contains("win") ? "windows" : "linux") + "-"
                + (arch.equals("amd64") || arch.equals("x86_64") ? "x86_64" : "aarch64");
        String ext = os.contains("mac") ? "dylib" : os.contains("win") ? "dll" : "so";
        Path library = Path.of(System.getProperty("limn.svg.dist", "native/dist/limn/svg/native"), platform,
                "liblimnsvg." + ext);
        Assumptions.assumeTrue(Files.isRegularFile(library),
                "no liblimnsvg built for " + platform + " (run scripts/build-lunasvg.sh)");
        System.load(library.toAbsolutePath().toString());
    }

    private static byte[] utf8(String s) {
        return s.getBytes(StandardCharsets.UTF_8);
    }

    private static final String SQUARE = "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='10'>"
            + "<rect id='box' x='0' y='0' width='10' height='10' fill='#ff0000'/></svg>";

    @Test
    void theHandshakeAndTheVersionAreWhatThisRepositorySays() {
        assertEquals(1, LunaSvgNative.abi());
        assertEquals("3.5.0", LunaSvgNative.lunasvgVersion());
    }

    @Test
    void aDocumentIsMeasuredDrawnChangedAndClosed() {
        long doc = LunaSvgNative.open(utf8(SQUARE));
        assertNotEquals(0, doc);
        try {
            float[] size = new float[2];
            assertTrue(LunaSvgNative.size(doc, size));
            assertArrayEquals(new float[] {20, 10}, size);

            byte[] pixels = new byte[20 * 10 * 4];
            assertTrue(LunaSvgNative.render(doc, 20, 10, pixels));
            int inside = (5 * 20 + 5) * 4;
            int outside = (5 * 20 + 15) * 4;
            assertEquals(0xFF, pixels[inside] & 0xFF, "red inside the box");
            assertEquals(0xFF, pixels[inside + 3] & 0xFF, "opaque inside the box");
            assertEquals(0, pixels[outside + 3] & 0xFF, "nothing beside it");

            assertTrue(LunaSvgNative.setAttribute(doc, utf8("box"), utf8("fill"), utf8("#0000ff")));
            assertTrue(LunaSvgNative.render(doc, 20, 10, pixels));
            assertEquals(0, pixels[inside] & 0xFF, "no longer red");
            assertEquals(0xFF, pixels[inside + 2] & 0xFF, "blue now");

            assertTrue(LunaSvgNative.setAttribute(doc, utf8("box"), utf8("x"), utf8("10")));
            assertTrue(LunaSvgNative.render(doc, 20, 10, pixels));
            assertEquals(0, pixels[inside + 3] & 0xFF, "moved away");
            assertEquals(0xFF, pixels[outside + 3] & 0xFF, "moved here");

            assertFalse(LunaSvgNative.setAttribute(doc, utf8("nobody"), utf8("fill"), utf8("red")),
                    "no element by that id");
            assertFalse(LunaSvgNative.render(doc, 20, 10, new byte[16]), "a buffer too small is refused");
            assertFalse(LunaSvgNative.render(doc, 0, 10, pixels), "no size, no drawing");
        } finally {
            LunaSvgNative.close(doc);
        }
        LunaSvgNative.close(0);
    }

    @Test
    void scalingDrawsTheSameShapeLarger() {
        long doc = LunaSvgNative.open(utf8(SQUARE));
        try {
            byte[] pixels = new byte[80 * 40 * 4];
            assertTrue(LunaSvgNative.render(doc, 80, 40, pixels));
            assertEquals(0xFF, pixels[(20 * 80 + 20) * 4 + 3] & 0xFF, "the box, four times larger");
            assertEquals(0, pixels[(20 * 80 + 60) * 4 + 3] & 0xFF);
        } finally {
            LunaSvgNative.close(doc);
        }
    }

    @Test
    void whatIsNoSvgIsRefusedAndNothingCrashes() {
        assertEquals(0, LunaSvgNative.open(utf8("not an svg at all")));
        assertEquals(0, LunaSvgNative.open(new byte[0]));
        assertEquals(0, LunaSvgNative.open(null));
        assertFalse(LunaSvgNative.size(0, new float[2]));
        assertFalse(LunaSvgNative.addFont(utf8("Nothing"), false, false, new byte[] {1, 2, 3}),
                "bytes that are no font are refused, and freed once");
    }

    /**
     * The case the fuzz found on Linux: a dashed circle at x = 9,999,912, whose curves plutovg
     * flattened without end until patches/plutovg-flatten-split-budget.patch gave each a budget.
     * Unpatched, this test never returns: the native call spins, and the timeout reports it.
     */
    @Test
    void aCurveFarFromTheOriginIsDrawnAndInTime() throws Exception {
        byte[] svg = Files.readAllBytes(Path.of("src/test/fuzz/seeds/far-dashed-circle.svg"));
        org.junit.jupiter.api.Assertions.assertTimeoutPreemptively(java.time.Duration.ofSeconds(10), () -> {
            long doc = LunaSvgNative.open(svg);
            assertNotEquals(0, doc);
            try {
                for (int side : new int[] {16, 256}) {
                    assertTrue(LunaSvgNative.render(doc, side, side, new byte[side * side * 4]), "at " + side);
                }
            } finally {
                LunaSvgNative.close(doc);
            }
        });
    }

    @Test
    void textOutsideAsciiReachesAnAttributeWhole() {
        long doc = LunaSvgNative.open(utf8("<svg xmlns='http://www.w3.org/2000/svg' width='4' height='4'>"
                + "<rect id='ação' width='4' height='4' fill='red'/></svg>"));
        try {
            assertTrue(LunaSvgNative.setAttribute(doc, utf8("ação"), utf8("fill"), utf8("lime")));
        } finally {
            LunaSvgNative.close(doc);
        }
    }

    @Test
    void manyThreadsDrawAtOnceAndEachGetsItsOwnPicture() throws Exception {
        ExecutorService pool = Executors.newFixedThreadPool(8);
        try {
            List<Future<Boolean>> runs = new ArrayList<>();
            for (int t = 0; t < 8; t++) {
                int colour = t;
                runs.add(pool.submit(() -> {
                    for (int i = 0; i < 200; i++) {
                        String fill = String.format("#%02x0000", 30 * colour);
                        long doc = LunaSvgNative.open(utf8(SQUARE.replace("#ff0000", fill)));
                        byte[] pixels = new byte[20 * 10 * 4];
                        boolean drawn = LunaSvgNative.render(doc, 20, 10, pixels);
                        LunaSvgNative.close(doc);
                        if (!drawn || (pixels[(5 * 20 + 5) * 4] & 0xFF) != 30 * colour) {
                            return false;
                        }
                    }
                    return true;
                }));
            }
            for (Future<Boolean> run : runs) {
                assertTrue(run.get(), "every thread saw its own colour every time");
            }
        } finally {
            pool.shutdownNow();
        }
    }
}
