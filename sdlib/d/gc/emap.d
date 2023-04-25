module d.gc.emap;

import d.gc.extent;
import d.gc.spec;
import d.gc.util;

@property
shared(ExtentMap)* gExtentMap() {
	static shared ExtentMap emap;

	if (emap.tree.base is null) {
		import d.gc.base;
		emap.tree.base = &gBase;
	}

	return &emap;
}

struct ExtentMap {
private:
	import d.gc.rtree;
	RTree!PageDescriptor tree;

public:
	PageDescriptor lookup(void* address) shared {
		auto leaf = tree.get(address);
		return leaf is null ? PageDescriptor(0) : leaf.load();
	}

	void remap(Extent* extent, ExtentClass ec) shared {
		batchMapImpl(extent.addr, extent.size, PageDescriptor(extent, ec));
	}

	void remap(Extent* extent) shared {
		// FIXME: in contract.
		assert(!extent.isSlab(), "Extent is a slab!");
		remap(extent, ExtentClass.large());
	}

	void clear(Extent* extent) shared {
		batchMapImpl(extent.addr, extent.size, PageDescriptor(0));
	}

private:
	void batchMapImpl(void* address, size_t size, PageDescriptor pd) shared {
		// FIXME: in contract.
		assert(isAligned(address, PageSize), "Incorrectly aligned address!");
		assert(isAligned(size, PageSize), "Incorrectly aligned size!");

		auto start = address;
		auto stop = start + size;

		for (auto ptr = start; ptr < stop; ptr += PageSize) {
			// FIXME: batch set, so we don't need L0 lookup again and again.
			tree.set(ptr, pd);
		}
	}
}

struct PageDescriptor {
private:
	/**
	 * The extent itself is 7 bits aligned and the address space 48 bits.
	 * This leaves us with the low 7 bits and the high 16 bits int he extent's
	 * pointer to play with.
	 * 
	 * We use these bits to pack the following data in the descriptor:
	 *  - a: The arena index.
	 *  - e: The extent class.
	 *  - p: The extent pointer.
	 * 
	 * 63    56 55    48 47    40 39             8 7      0
	 * ....aaaa aaaaaaaa pppppppp [extent pointer] p.eeeeee
	 */
	ulong data;

package:
	this(ulong data) {
		this.data = data;
	}

public:
	this(Extent* extent, ExtentClass ec) {
		// FIXME: in contract.
		assert(isAligned(extent, ExtentAlign), "Invalid Extent alignment!");
		assert(extent.extentClass.data == ec.data, "Invalid ExtentClass!");

		data = ec.data;
		data |= cast(size_t) extent;
		data |= ulong(extent.arenaIndex) << 48;
	}

	auto toLeafPayload() const {
		return data;
	}

	@property
	Extent* extent() {
		return cast(Extent*) (data & ExtentMask);
	}

	@property
	auto extentClass() const {
		return ExtentClass(data & ExtentClass.Mask);
	}

	bool isSlab() const {
		auto ec = extentClass;
		return ec.isSlab();
	}

	@property
	ubyte sizeClass() const {
		auto ec = extentClass;
		return ec.sizeClass;
	}

	@property
	uint arenaIndex() const {
		return (data >> 48) & ArenaMask;
	}

	@property
	bool containsPointers() const {
		return (arenaIndex & 0x01) != 0;
	}

	@property
	auto arena() const {
		import d.gc.arena;
		return Arena.getInitialized(arenaIndex);
	}
}

unittest ExtentMap {
	import d.gc.base;
	shared Base base;
	scope(exit) base.clear();

	static shared ExtentMap emap;
	emap.tree.base = &base;

	// We have not mapped anything.
	auto ptr = cast(void*) 0x56789abcd000;
	assert(emap.lookup(ptr).data == 0);

	auto slot = base.allocSlot();
	auto e = Extent.fromSlot(0, slot);
	e.at(ptr, 5 * PageSize, null);

	// Map a range.
	emap.remap(e);
	auto pd = PageDescriptor(e, e.extentClass);

	auto end = ptr + e.size;
	for (auto p = ptr; p < end; p += PageSize) {
		assert(emap.lookup(p).data == pd.data);
	}

	assert(emap.lookup(end).data == 0);

	// Clear a range.
	emap.clear(e);
	for (auto p = ptr; p < end; p += PageSize) {
		assert(emap.lookup(p).data == 0);
	}
}
