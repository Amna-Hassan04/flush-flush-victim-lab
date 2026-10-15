
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
#define MESSAGE "amna"
#define BITS (sizeof(MESSAGE) - 1) * 8

typedef struct {
    _Atomic int go;
    _Atomic int ready;
    _Atomic int ack;
    _Alignas(64) volatile uint8_t target[64];
} SharedData;

int main(void) {
    int fd = shm_open(SHM_NAME, O_CREAT | O_RDWR, 0600);
    if (fd == -1) {
        perror("shm_open");
        return 1;
    }

    if (ftruncate(fd, sizeof(SharedData)) == -1) {
        perror("ftruncate");
        close(fd);
        shm_unlink(SHM_NAME);
        return 1;
    }

    SharedData *s = mmap(NULL, sizeof(SharedData),
                         PROT_READ | PROT_WRITE,
                         MAP_SHARED, fd, 0);
    close(fd);

    if (s == MAP_FAILED) {
        perror("mmap");
        shm_unlink(SHM_NAME);
        return 1;
    }

    atomic_init(&s->go, 0);
    atomic_init(&s->ready, 0);
    atomic_init(&s->ack, 0);
    s->target[0] = 0;

    printf("Victim ready. Waiting for observer...\n");
    fflush(stdout);

    for (int i = 0; i < BITS; i++) {
        while (atomic_load_explicit(&s->go, memory_order_acquire)
               != i + 1)
            sched_yield();

        unsigned char ch = MESSAGE[i / 8];
        int bit = (ch >> (7 - (i % 8))) & 1;

        if (bit)
            s->target[0] = (uint8_t)(i + 1);

        _mm_mfence();

        atomic_store_explicit(&s->ready, i + 1,
                              memory_order_release);

        while (atomic_load_explicit(&s->ack, memory_order_acquire)
               != i + 1)
            sched_yield();
    }

    printf("Victim finished sending %d test bits.\n", BITS);

    munmap(s, sizeof(SharedData));
    shm_unlink(SHM_NAME);
    return 0;
}
