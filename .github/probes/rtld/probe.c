/*
 * Many threads dlopen and dlclose the same object at once.
 *
 * NetBSD's rtld holds one exclusive lock but has to drop it to run an
 * object's constructors and destructors, and an object being worked on
 * can be invalidated by another thread in that window.  -current fixed a
 * series of these in 2026 (libexec/ld.elf_so, "Resolve several races in
 * dlopen/dlclose" and "Fix more races with recursive threaded
 * dlopen/dlclose"); NetBSD 10 does not have them.
 *
 * Prints the number of iterations completed, or dies where it dies.
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *dso_path;
static int iterations = 2000;
static volatile int stop;

static void *
worker(void *arg)
{
	long id = (long)arg;
	int i;

	for (i = 0; i < iterations && !stop; i++) {
		void *h = dlopen(dso_path, RTLD_NOW | RTLD_LOCAL);
		if (h == NULL) {
			fprintf(stderr, "thread %ld: dlopen failed at %d: %s\n",
			    id, i, dlerror());
			stop = 1;
			return (void *)(long)i;
		}
		int (*f)(void) = (int (*)(void))dlsym(h, "dso_value");
		if (f != NULL)
			(void)f();
		if (dlclose(h) != 0) {
			fprintf(stderr, "thread %ld: dlclose failed at %d: %s\n",
			    id, i, dlerror());
			stop = 1;
			return (void *)(long)i;
		}
	}
	return (void *)(long)i;
}

int
main(int argc, char **argv)
{
	long nthreads = 8;
	pthread_t *t;
	long i;

	if (argc < 2) {
		fprintf(stderr, "usage: %s /path/to/dso.so [threads] [iterations]\n",
		    argv[0]);
		return 2;
	}
	dso_path = argv[1];
	if (argc > 2)
		nthreads = strtol(argv[2], NULL, 10);
	if (argc > 3)
		iterations = (int)strtol(argv[3], NULL, 10);

	printf("%ld threads, %d iterations each, on %s\n",
	    nthreads, iterations, dso_path);
	fflush(stdout);

	t = calloc((size_t)nthreads, sizeof(*t));
	if (t == NULL)
		return 2;
	for (i = 0; i < nthreads; i++) {
		if (pthread_create(&t[i], NULL, worker, (void *)i) != 0) {
			perror("pthread_create");
			return 2;
		}
	}
	long done = 0;
	for (i = 0; i < nthreads; i++) {
		void *r;
		pthread_join(t[i], &r);
		done += (long)r;
	}
	printf("completed %ld iterations across %ld threads\n", done, nthreads);
	return stop ? 1 : 0;
}
