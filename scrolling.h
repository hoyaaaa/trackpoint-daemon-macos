/* Independent implementation of observed Preferred Scrolling protocol rules.
 * Windows emits 120-unit wheel notches; callers use native OS line units.
 * See docs/windows-scrolling.md for evidence and platform boundaries. */
#include <stdint.h>
#include <limits.h>
typedef struct { int32_t pending; int lastMagnitude; } TPWheelBatch;
static int tp_wheel_units(uint8_t raw) {
    if (raw >= 1 && raw <= 7) return raw;
    if (raw >= 0xf9) return -(raw == 0xff ? 1 : 0xff - raw);
    return 0;
}
static int tp_wheel_feed(TPWheelBatch *batch, uint8_t horizontal, uint8_t vertical) {
    if (horizontal && vertical) return 0;
    int x=tp_wheel_units(horizontal), y=tp_wheel_units(vertical);
    int direction=(x>0)-(x<0)+(y>0)-(y<0);
    if (direction>0 && batch->pending<INT32_MAX) batch->pending++;
    if (direction<0 && batch->pending>INT32_MIN) batch->pending--;
    if (y) batch->lastMagnitude=y<0 ? -y : y;
    return (x>0)-(x<0);
}
static int32_t tp_wheel_take(TPWheelBatch *batch) {
    int64_t value=(int64_t)batch->pending*batch->lastMagnitude;
    *batch=(TPWheelBatch){0};
    return value>INT32_MAX ? INT32_MAX : value<INT32_MIN ? INT32_MIN : (int32_t)value;
}
