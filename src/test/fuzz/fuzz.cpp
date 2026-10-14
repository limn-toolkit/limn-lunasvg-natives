// Mutation fuzz of lunasvg as this repository builds it: every case a damaged copy of a seed,
// opened, changed and drawn at a size, in a child process, so that a crash or a hang is counted and
// not suffered. ADR 066 in limn-toolkit asks that each lunasvg this repository packages pass it;
// scripts/fuzz.sh builds it against the release objects and fails on any crash or hang.
//
// The mutations are the ones that reach past the XML parser: digits changed or grown (sizes,
// coordinates, counts), characters deleted (a closing quote, half a tag), punctuation dropped in,
// minus signs before numbers. Byte noise alone is refused at the first character and proves nothing.
//
// usage: fuzz <cases> <seed> <seconds a case may take> file...

#include <lunasvg.h>

#include <cctype>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

static int draw(const std::string& text, int size) {
    auto doc = lunasvg::Document::loadFromData(text);
    if (!doc) {
        return 1;
    }
    for (const char* id : {"a", "b", "s", "g", "box"}) {
        lunasvg::Element element = doc->getElementById(id);
        if (!element.isNull()) {
            element.setAttribute("fill", "#123456");
            element.setAttribute("x", "-99999");
        }
    }
    auto bitmap = doc->renderToBitmap(size, size, 0);
    return bitmap.isNull() ? 1 : 0;
}

static size_t nextDigit(const std::string& d, size_t at) {
    for (size_t step = 0; step < d.size() && !std::isdigit(static_cast<unsigned char>(d[at])); step++) {
        at = (at + 1) % d.size();
    }
    return at;
}

int main(int argc, char** argv) {
    if (argc < 5) {
        std::fprintf(stderr, "usage: fuzz <cases> <seed> <seconds> file...\n");
        return 2;
    }
    int cases = std::atoi(argv[1]);
    std::srand(static_cast<unsigned>(std::atoi(argv[2])));
    int seconds = std::atoi(argv[3]);
    std::vector<std::string> seeds;
    for (int i = 4; i < argc; i++) {
        FILE* f = std::fopen(argv[i], "rb");
        if (f == nullptr) {
            std::fprintf(stderr, "cannot read %s\n", argv[i]);
            return 2;
        }
        std::string s;
        char buf[65536];
        size_t n;
        while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) s.append(buf, n);
        std::fclose(f);
        seeds.push_back(s);
    }
    int drawn = 0, refused = 0, crashed = 0, hung = 0;
    for (int k = 0; k < cases; k++) {
        std::string d = seeds[static_cast<size_t>(std::rand()) % seeds.size()];
        int mutations = 1 + std::rand() % 6;
        for (int m = 0; m < mutations && !d.empty(); m++) {
            size_t at = static_cast<size_t>(std::rand()) % d.size();
            switch (std::rand() % 5) {
                case 0: at = nextDigit(d, at); d[at] = static_cast<char>('0' + std::rand() % 10); break;
                case 1: d.insert(nextDigit(d, at), "99999"); break;
                case 2: d.erase(at, 1 + static_cast<size_t>(std::rand() % 16)); break;
                case 3: d.insert(at, 1, "\"<>/=#();"[std::rand() % 9]); break;
                default: d.insert(nextDigit(d, at), "-"); break;
            }
        }
        int size = 16 << (std::rand() % 5);
        pid_t child = fork();
        if (child == 0) {
            alarm(static_cast<unsigned>(seconds));
            _exit(draw(d, size));
        }
        int status = 0;
        waitpid(child, &status, 0);
        if (WIFEXITED(status)) {
            (WEXITSTATUS(status) == 0 ? drawn : refused)++;
        } else if (WTERMSIG(status) == SIGALRM) {
            hung++;
        } else {
            crashed++;
            char name[64];
            std::snprintf(name, sizeof name, "crash-%d.svg", k);
            if (FILE* out = std::fopen(name, "wb")) {
                std::fwrite(d.data(), 1, d.size(), out);
                std::fclose(out);
            }
        }
    }
    std::printf("cases=%d drawn=%d refused=%d crashed=%d hung=%d\n", cases, drawn, refused, crashed, hung);
    return crashed == 0 && hung == 0 ? 0 : 1;
}
