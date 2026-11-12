// LD_PRELOAD shim that lets stock Quickshell host a QtWebEngine WebEngineView.
//
// Quickshell constructs its app as `new QGuiApplication(qArgC /* = 0 */, argv)`,
// and QtWebEngine aborts when QCoreApplication::arguments() is empty
// ("Argument list is empty, the program name is not passed to QCoreApplication").
// QtWebEngine also wants Qt::AA_ShareOpenGLContexts set before the app exists
// (what QtWebEngineQuick::initialize() would do in a normal app).
//
// We wrap QGuiApplication's constructor: set the attribute, pass argc = 1, then
// remove ourselves from LD_PRELOAD so QtWebEngineProcess children don't inherit it.
//
// Portable on purpose (shipped prebuilt in release tarballs): only plain C string
// functions from glibc and two Qt 6 symbols - no libstdc++ types, so it doesn't need
// a newer C++ runtime than the target distro has.
//
// Build: make   Used by: bin/apt-layer (LD_PRELOAD=lib/libqs-webengine-shim.so qs -p quickshell)

#include <QtCore/QCoreApplication>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

namespace {

int g_argc = 1;
char g_arg0[] = "quickshell";
char* g_argv[] = {g_arg0, nullptr};

// LD_PRELOAD without our own entry (entries are separated by ':' or ' ').
void dropSelfFromPreload() {
	const char* cur = getenv("LD_PRELOAD");
	if (!cur) return;
	size_t len = strlen(cur);
	char* out = static_cast<char*>(malloc(len + 1));
	if (!out) return;
	size_t o = 0;
	const char* p = cur;
	while (*p) {
		size_t n = strcspn(p, ": ");
		bool ours = false;
		for (size_t i = 0; i + 17 <= n && !ours; i++) ours = memcmp(p + i, "qs-webengine-shim", 17) == 0;
		if (n > 0 && !ours) {
			if (o > 0) out[o++] = ':';
			memcpy(out + o, p, n);
			o += n;
		}
		p += n;
		if (*p) p++;
	}
	out[o] = '\0';
	if (o == 0) unsetenv("LD_PRELOAD");
	else setenv("LD_PRELOAD", out, 1);
	free(out);
}

} // namespace

// QGuiApplication::QGuiApplication(int &argc, char **argv, int flags) — complete-object ctor.
extern "C" void _ZN15QGuiApplicationC1ERiPPci(void* self, int& argc, char** argv, int flags) {
	using Ctor = void (*)(void*, int&, char**, int);
	static auto real = reinterpret_cast<Ctor>(dlvsym(RTLD_NEXT, "_ZN15QGuiApplicationC1ERiPPci", "Qt_6"));
	if (!real) abort();

	QCoreApplication::setAttribute(Qt::AA_ShareOpenGLContexts);
	dropSelfFromPreload();

	if (argc > 0) real(self, argc, argv, flags);
	else real(self, g_argc, g_argv, flags); // Qt keeps a reference to argc: must outlive the app
}
