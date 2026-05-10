#include <elf.h>
#include <stddef.h>

#ifdef __FDPIC__

struct elf32_fdpic_loadseg {
	Elf32_Addr addr;
	Elf32_Addr p_vaddr;
	Elf32_Word p_memsz;
};

struct elf32_fdpic_loadmap {
	Elf32_Half version;
	Elf32_Half nsegs;
	struct elf32_fdpic_loadseg segs[];
};

static inline __attribute__((always_inline)) void *reloc_pointer(
	void *p, const struct elf32_fdpic_loadmap *map)
{
	int c;

	for (c = 0; c < map->nsegs && p >= (void *)map->segs[c].p_vaddr; c++) {
		unsigned long offset = (char *)p - (char *)map->segs[c].p_vaddr;
		if (offset < map->segs[c].p_memsz ||
		    (offset == map->segs[c].p_memsz && c + 1 == map->nsegs))
			return (char *)map->segs[c].addr + offset;
	}

	return (void *)-1;
}

static inline __attribute__((always_inline)) void ***reloc_range_indirect(
	void ***p, void ***e, const struct elf32_fdpic_loadmap *map)
{
	while (p < e) {
		if (*p != (void **)-1) {
			void *ptr = reloc_pointer(*p, map);
			if (ptr != (void *)-1) {
				void *pt;
				if ((long)ptr & 3) {
					unsigned char *c = ptr;
					int i;
					unsigned long v = 0;
					for (i = 0; i < 4; i++)
						v |= c[i] << (8 * i);
					pt = (void *)v;
				} else {
					pt = *(void **)ptr;
				}
				pt = reloc_pointer(pt, map);
				if ((long)ptr & 3) {
					unsigned char *c = ptr;
					int i;
					unsigned long v = (unsigned long)pt;
					for (i = 0; i < 4; i++, v >>= 8)
						c[i] = v;
				} else {
					*(void **)ptr = pt;
				}
			}
		}
		p++;
	}
	return p;
}

void *__self_reloc(const struct elf32_fdpic_loadmap *map, void ***p, void ***e)
{
	p = reloc_range_indirect(p, e - 1, map);
	if (p >= e)
		return (void *)-1;
	return reloc_pointer(*p, map);
}

#endif
