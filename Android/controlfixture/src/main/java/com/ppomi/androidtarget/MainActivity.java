package com.ppomi.androidtarget;

import android.app.Activity;
import android.os.Bundle;
import android.view.View;
import android.view.MotionEvent;
import android.view.Gravity;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Separate package: verifies that the bridge controls another app through accessibility. */
public final class MainActivity extends Activity {
    private int count;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setPadding(32, 100, 32, 32);
        TextView title = new TextView(this);
        title.setText("Ppomi · Android control test");
        title.setTextSize(24);
        layout.addView(title);
        LinearLayout protectedParent = new LinearLayout(this);
        protectedParent.setOrientation(LinearLayout.VERTICAL);
        protectedParent.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
        protectedParent.setClickable(true);
        TextView protectedLabel = new TextView(this);
        protectedLabel.setText("송금");
        protectedLabel.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
        protectedParent.addView(protectedLabel);
        TextView protectedResult = new TextView(this);
        protectedResult.setText("Protected fixture count: 0");
        protectedParent.setOnClickListener(view -> protectedResult.setText("Protected fixture count: 1"));
        layout.addView(protectedParent);
        layout.addView(protectedResult);
        LinearLayout publisherCard = new LinearLayout(this);
        publisherCard.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
        publisherCard.setClickable(true);
        TextView publisherLabel = new TextView(this);
        publisherLabel.setText("Publisher card");
        publisherLabel.setContentDescription("어카운트인포-계좌통합관리\n금융결제원(KFTC)\n금융\n별표 평점: 3.4\n500만회 이상 다운로드됨\n");
        publisherLabel.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
        publisherCard.addView(publisherLabel);
        TextView publisherResult = new TextView(this);
        publisherResult.setText("Publisher fixture count: 0");
        publisherCard.setOnClickListener(view -> publisherResult.setText("Publisher fixture count: 1"));
        layout.addView(publisherCard);
        layout.addView(publisherResult);
        TextView result = new TextView(this);
        result.setText("Count: 0");
        result.setTextSize(22);
        result.setContentDescription("counter");
        layout.addView(result);
        Button increment = new Button(this);
        increment.setText("Increment");
        increment.setOnClickListener(view -> result.setText("Count: " + (++count)));
        layout.addView(increment);
        EditText input = new EditText(this);
        input.setId(View.generateViewId());
        input.setHint("Enter test text");
        input.setSingleLine(true);
        input.setContentDescription("test input");
        layout.addView(input);
        Button submit = new Button(this);
        submit.setText("Apply text");
        TextView output = new TextView(this);
        output.setText("Applied: (empty)");
        submit.setOnClickListener(view -> output.setText("Applied: " + input.getText()));
        layout.addView(submit);
        layout.addView(output);
        Button hold = new Button(this);
        hold.setText("Long press test");
        hold.setContentDescription("long press target");
        TextView holdResult = new TextView(this);
        holdResult.setText("Hold: none");
        hold.setOnLongClickListener(view -> { holdResult.setText("Hold: completed"); return true; });
        layout.addView(hold);
        layout.addView(holdResult);
        TextView drag = new TextView(this);
        drag.setText("Hold then drag");
        drag.setContentDescription("drag source");
        drag.setLongClickable(true);
        drag.setGravity(Gravity.CENTER);
        drag.setPadding(20, 45, 20, 45);
        drag.setBackgroundColor(0xffbad7ff);
        TextView drop = new TextView(this);
        drop.setText("Drop here");
        drop.setContentDescription("drop target");
        drop.setGravity(Gravity.CENTER);
        drop.setPadding(20, 45, 20, 45);
        drop.setBackgroundColor(0xffcbe8d1);
        TextView dragResult = new TextView(this);
        dragResult.setText("Drag: none");
        long[] downAt = {0};
        boolean[] heldBeforeMoving = {false};
        float[] origin = new float[2];
        drag.setOnTouchListener((view, event) -> {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    downAt[0] = event.getEventTime();
                    origin[0] = event.getRawX(); origin[1] = event.getRawY();
                    heldBeforeMoving[0] = false;
                    dragResult.setText("Drag: holding");
                    return true;
                case MotionEvent.ACTION_MOVE:
                    if (Math.hypot(event.getRawX() - origin[0], event.getRawY() - origin[1]) < 15
                        && event.getEventTime() - downAt[0] >= 450) heldBeforeMoving[0] = true;
                    // A continued pointer may first report movement only when the hold ends.
                    if (event.getEventTime() - downAt[0] >= 500 && Math.hypot(event.getRawX() - origin[0], event.getRawY() - origin[1]) < 60)
                        heldBeforeMoving[0] = true;
                    return true;
                case MotionEvent.ACTION_UP:
                    int[] location = new int[2]; drop.getLocationOnScreen(location);
                    boolean inside = event.getRawX() >= location[0] && event.getRawX() < location[0] + drop.getWidth()
                        && event.getRawY() >= location[1] && event.getRawY() < location[1] + drop.getHeight();
                    dragResult.setText(inside && heldBeforeMoving[0] ? "Drag: completed" : "Drag: not dropped");
                    return true;
                case MotionEvent.ACTION_CANCEL:
                    dragResult.setText("Drag: cancelled"); return true;
                default: return true;
            }
        });
        layout.addView(drag);
        layout.addView(drop);
        layout.addView(dragResult);
        setContentView(layout);
    }
}
