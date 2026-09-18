/*
 * The object the threads keep loading and unloading.  It has a
 * constructor, because the races being exercised are the ones rtld runs
 * into when it drops its lock to call constructors and destructors.
 */
#include <stdlib.h>

static volatile int counter;

__attribute__((constructor))
static void ctor(void)
{
	counter++;
}

__attribute__((destructor))
static void dtor(void)
{
	counter--;
}

int
dso_value(void)
{
	return counter;
}
