
#include <fcntl.h>
#include <immintrin.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define SHM_NAME "/flush_flush_demo"
#define BITS 32

typedef struct {
    _Atomic int go;
    _Atomic int ready;
    _Atomic int ack;
    _Alignas(64) volatile uint8_t target[64];
} SharedData;

static uint64_t timed_flush(volatile uint8_t *p) {
    unsigned int aux;

    _mm_mfence();
    uint64_t start = __rdtscp(&aux);
    _mm_clflush((const void *)p);
    _mm_mfence();
    uint64_t end = __rdtscp(&aux);

    return end - start;
}

int main(void) {
    int fd = shm_open(SHM_NAME, O_RDWR, 0600);
    if (fd == -1) {
        perror("shm_open");
        fprintf(stderr, "Start the victim first.\n");
        return 1;
    }

    SharedData *s = mmap(NULL, sizeof(SharedData),
                         PROT_READ | PROT_WRITE,
                         MAP_SHARED, fd, 0);
    close(fd);

    if (s == MAP_FAILED) {
        perror("mmap");
        return 1;
    }

    FILE *out = fopen("victim_timings.csv", "w");
    if (!out) {
        perror("fopen");
        munmap(s, sizeof(SharedData));
        return 1;
    }

    fprintf(out, "bit_index,ticks\n");

    printf("Observer started. Measuring cache timings...\n");

    for (int i = 0; i < BITS; i++) {
        _mm_clflush((const void *)s->target);
        _mm_mfence();

        atomic_store_explicit(&s->go, i + 1,
                              memory_order_release);

        while (atomic_load_explicit(&s->ready, memory_order_acquire)
               != i + 1)
            sched_yield();

        uint64_t ticks = timed_flush(s->target);

        fprintf(out, "%d,%llu\n", i,
                (unsigned long long)ticks);
        fflush(out);

        atomic_store_explicit(&s->ack, i + 1,
                              memory_order_release);
    }

    fclose(out);
    munmap(s, sizeof(SharedData));

    printf("Finished. Results saved to victim_timings.csv\n");
    return 0;
}
