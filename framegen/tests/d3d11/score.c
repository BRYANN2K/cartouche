// Scores a captured frame against the reference: PSNR over RGB and SSIM over luma (8x8 windows,
// stride 4). The reference is box-filtered down to the frame's size (the ss capture is twice as
// big); a smaller frame is brought up with bilinear filtering first, as a plain upscale would.
// Usage: score <reference.ppm> <frame.ppm>   prints "psnr_db=... ssim=..."
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
	int w, h;
	float *rgb;
} Image;

static Image load(const char *path)
{
	Image im = { 0, 0, NULL };
	FILE *f = fopen(path, "rb");
	int max = 0;
	if (f == NULL || fscanf(f, "P6 %d %d %d", &im.w, &im.h, &max) != 3 || max != 255 || fgetc(f) == EOF) {
		fprintf(stderr, "score: cannot read %s\n", path);
		exit(2);
	}
	size_t n = (size_t)im.w * im.h * 3;
	unsigned char *raw = malloc(n);
	im.rgb = malloc(n * sizeof(float));
	if (fread(raw, 1, n, f) != n) {
		fprintf(stderr, "score: %s is short\n", path);
		exit(2);
	}
	for (size_t i = 0; i < n; i++)
		im.rgb[i] = raw[i];
	free(raw);
	fclose(f);
	return im;
}

static Image box_down(Image src, int w, int h)
{
	Image out = { w, h, calloc((size_t)w * h * 3, sizeof(float)) };
	int fx = src.w / w, fy = src.h / h;
	for (int y = 0; y < h; y++)
		for (int x = 0; x < w; x++)
			for (int c = 0; c < 3; c++) {
				float sum = 0;
				for (int j = 0; j < fy; j++)
					for (int i = 0; i < fx; i++)
						sum += src.rgb[(((size_t)y * fy + j) * src.w + (size_t)x * fx + i) * 3 + c];
				out.rgb[((size_t)y * w + x) * 3 + c] = sum / (float)(fx * fy);
			}
	return out;
}

static float at(Image im, int x, int y, int c)
{
	x = x < 0 ? 0 : x >= im.w ? im.w - 1 : x;
	y = y < 0 ? 0 : y >= im.h ? im.h - 1 : y;
	return im.rgb[((size_t)y * im.w + x) * 3 + c];
}

static Image bilinear_up(Image src, int w, int h)
{
	Image out = { w, h, malloc((size_t)w * h * 3 * sizeof(float)) };
	for (int y = 0; y < h; y++)
		for (int x = 0; x < w; x++) {
			float sx = ((float)x + 0.5f) * src.w / w - 0.5f, sy = ((float)y + 0.5f) * src.h / h - 0.5f;
			int x0 = (int)floorf(sx), y0 = (int)floorf(sy);
			float ax = sx - x0, ay = sy - y0;
			for (int c = 0; c < 3; c++)
				out.rgb[((size_t)y * w + x) * 3 + c] =
					(1 - ay) * ((1 - ax) * at(src, x0, y0, c) + ax * at(src, x0 + 1, y0, c)) +
					ay * ((1 - ax) * at(src, x0, y0 + 1, c) + ax * at(src, x0 + 1, y0 + 1, c));
		}
	return out;
}

static float luma(Image im, int x, int y)
{
	return 0.299f * at(im, x, y, 0) + 0.587f * at(im, x, y, 1) + 0.114f * at(im, x, y, 2);
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fputs("usage: score <reference.ppm> <frame.ppm>\n", stderr);
		return 2;
	}
	Image ref = load(argv[1]), im = load(argv[2]);
	if (im.w < 1280)
		im = bilinear_up(im, 1280, 720);
	if (ref.w != im.w)
		ref = box_down(ref, im.w, im.h);
	double se = 0;
	size_t n = (size_t)im.w * im.h * 3;
	for (size_t i = 0; i < n; i++)
		se += (double)(im.rgb[i] - ref.rgb[i]) * (im.rgb[i] - ref.rgb[i]);
	double psnr = 10 * log10(255.0 * 255.0 / (se / (double)n));
	const double c1 = 6.5025, c2 = 58.5225;
	double ssim = 0;
	long windows = 0;
	for (int y = 0; y + 8 <= im.h; y += 4)
		for (int x = 0; x + 8 <= im.w; x += 4) {
			double ma = 0, mb = 0, va = 0, vb = 0, cov = 0;
			for (int j = 0; j < 8; j++)
				for (int i = 0; i < 8; i++) {
					double a = luma(ref, x + i, y + j), b = luma(im, x + i, y + j);
					ma += a, mb += b, va += a * a, vb += b * b, cov += a * b;
				}
			ma /= 64, mb /= 64;
			va = va / 64 - ma * ma, vb = vb / 64 - mb * mb, cov = cov / 64 - ma * mb;
			ssim += (2 * ma * mb + c1) * (2 * cov + c2) / ((ma * ma + mb * mb + c1) * (va + vb + c2));
			windows++;
		}
	printf("psnr_db=%.2f ssim=%.4f\n", psnr, ssim / (double)windows);
	return 0;
}
