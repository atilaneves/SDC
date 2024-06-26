module d.thread;

extern(C) void __sd_process_create() {
	import d.gc.capi;
	__sd_gc_init();

	import d.rt.elf;
	registerMutableSegments();
	registerTlsSegments();
}

extern(C) void __sd_thread_create() {
	import d.gc.capi;
	__sd_gc_init();

	import d.rt.elf;
	registerTlsSegments();
}

extern(C) void __sd_thread_destroy() {
	import d.gc.capi;
	__sd_gc_destroy_thread();
}

alias ScanDg = void delegate(const(void*)[] range);
extern(C) void __sd_thread_scan(ScanDg scan) {
	// Scan the registered TLS segments.
	import d.gc.tcache;
	foreach (s; threadCache.tlsSegments) {
		scan(s);
	}

	import d.rt.stack;
	__sd_stack_scan(scan);
}

extern(C) void __sd_global_scan(ScanDg scan) {
	import d.gc.global;
	gState.scanRoots(scan);
}

extern(C) void __sd_thread_stop_the_world() {
	// TODO: Actually stop the world.
}

extern(C) void __sd_thread_restart_the_world() {
	// TODO: Actually stop the world.
}
