// The frame generation library reads its settings from the environment the run script
// builds from the game's options: CARTOUCHE_FRAMEGEN_TEMPORAL, CARTOUCHE_FRAMEGEN_UPSCALE,
// CARTOUCHE_OVERLAY and CARTOUCHE_OVERLAY_POS. The first byte picks the parser.
#import "fuzz.h"
#import "fg_overlay.h"
#import "fg_temporal.h"
#import "fg_upscale.h"
#import "fg_metrics.h"
#import "fg_pipeline.h"

// The parsers' units also draw; what they reach of the rest of the library is stubbed
_Atomic int FGCreatingInterpolator;
void FGMetricsRead(FGMetricsBlock *block) { memset(block, 0, sizeof *block); }

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 1) return 0;
    char *text = fz_cstr(data + 1, size - 1);
    switch (data[0] % 4) {
    case 0: {
        FGTemporalSettings s = FGTemporalDefaults();
        FGTemporalParse(text, &s);
        break;
    }
    case 1: {
        FGUpscaleSettings s;
        FGUpscaleParse(text, &s);
        break;
    }
    case 2: {
        FGOverlayLevel level;
        FGOverlayParseLevel(text, &level);
        break;
    }
    default: {
        FGOverlayCorner corner;
        FGOverlayParseCorner(text, &corner);
        break;
    }
    }
    free(text);
    return 0;
}
