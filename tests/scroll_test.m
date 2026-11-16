#include <assert.h>
#include <stdio.h>
#include "../scrolling.h"
int main(void) {
    for (int raw=0;raw<256;raw++) {
        int expected=raw>=1 && raw<=7 ? raw : raw>=249 ? -(raw==255 ? 1 : 255-raw) : 0;
        assert(tp_wheel_units(raw)==expected);
        TPWheelBatch batch={0};
        int horizontal=tp_wheel_feed(&batch,raw,0);
        assert(horizontal==((expected>0)-(expected<0)) && !tp_wheel_take(&batch));
        assert(!tp_wheel_feed(&batch,0,raw));
        assert(tp_wheel_take(&batch)==expected);
        assert(!tp_wheel_take(&batch));
    }
    TPWheelBatch batch={0};
    tp_wheel_feed(&batch,0,2);tp_wheel_feed(&batch,0,3);
    assert(tp_wheel_take(&batch)==6); // Desktop batch: count times most recent magnitude.
    tp_wheel_feed(&batch,0,1);tp_wheel_feed(&batch,0,255);
    assert(!tp_wheel_take(&batch)); // Opposite reports cancel inside the interval.
    tp_wheel_feed(&batch,0,3);tp_wheel_feed(&batch,1,0);
    assert(tp_wheel_take(&batch)==6); // The desktop path counts both accepted axes.
    assert(!tp_wheel_feed(&batch,2,3) && !tp_wheel_take(&batch));
    batch=(TPWheelBatch){INT32_MAX,7}; assert(tp_wheel_take(&batch)==INT32_MAX);
    batch=(TPWheelBatch){INT32_MIN,7}; assert(tp_wheel_take(&batch)==INT32_MIN);
    puts("Windows wheel protocol and batch policy tests: ok");
}
