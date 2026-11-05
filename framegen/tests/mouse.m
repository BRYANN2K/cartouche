// Mouse checks for upscaling: where the white marks a stand-in game drew are in a shown frame.
//
//   mouse marks <frame.ppm>   prints "mark <x> <y> <pixels>" per white blob, in pixels
//   mouse front               prints the bundle of the app in front

#import <AppKit/AppKit.h>

#import <stdio.h>
#import <stdlib.h>
#import <string.h>

static int marks(const char *path)
{
	FILE *file = fopen(path, "rb");
	int width, height, top;
	if (file == NULL || fscanf(file, "P6 %d %d %d", &width, &height, &top) != 3 || fgetc(file) == EOF) {
		fprintf(stderr, "mouse: no frame in %s\n", path);
		return 1;
	}
	size_t count = (size_t)width * (size_t)height;
	uint8_t *rgb = malloc(count * 3);
	int *label = calloc(count, sizeof(int));
	int *stack = malloc(count * sizeof(int));
	if (fread(rgb, 3, count, file) != count) {
		fprintf(stderr, "mouse: short frame\n");
		return 1;
	}
	fclose(file);
	int next = 0;
	for (size_t i = 0; i < count; i++) {
		if (label[i] || rgb[i * 3] < 200 || rgb[i * 3 + 1] < 200 || rgb[i * 3 + 2] < 200)
			continue;
		double sx = 0, sy = 0;
		long n = 0, depth = 0;
		label[i] = ++next;
		stack[depth++] = (int)i;
		while (depth > 0) {
			int at = stack[--depth], x = at % width, y = at / width;
			sx += x + 0.5;
			sy += y + 0.5;
			n++;
			const int around[4][2] = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } };
			for (int k = 0; k < 4; k++) {
				int nx = x + around[k][0], ny = y + around[k][1];
				if (nx < 0 || ny < 0 || nx >= width || ny >= height)
					continue;
				size_t j = (size_t)ny * (size_t)width + (size_t)nx;
				if (!label[j] && rgb[j * 3] >= 200 && rgb[j * 3 + 1] >= 200 && rgb[j * 3 + 2] >= 200) {
					label[j] = next;
					stack[depth++] = (int)j;
				}
			}
		}
		if (n >= 4)
			printf("mark %.2f %.2f %ld\n", sx / n, sy / n, n);
	}
	printf("size %d %d\n", width, height);
	return 0;
}

// The app in front, to check a test took no focus
static int front(void)
{
	printf("%s\n", (NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier ?: @"?").UTF8String);
	return 0;
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc == 3 && strcmp(argv[1], "marks") == 0)
			return marks(argv[2]);
		if (argc == 2 && strcmp(argv[1], "front") == 0)
			return front();
	}
	fprintf(stderr, "usage: mouse marks <frame.ppm> | mouse front\n");
	return 2;
}
