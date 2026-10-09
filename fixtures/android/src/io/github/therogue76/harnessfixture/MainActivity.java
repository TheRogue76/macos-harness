package io.github.therogue76.harnessfixture;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.os.Bundle;
import android.text.InputType;
import android.view.MotionEvent;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.Switch;
import android.widget.TextView;

/** An Android app with one of each kind of control, for testing macOS Harness against emulators and phones. */
public class MainActivity extends Activity {
    private int taps = 0;
    private int longPresses = 0;
    private int swipes = 0;
    private float touchStartX = 0;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        int padding = (int) (16 * getResources().getDisplayMetrics().density);
        column.setPadding(padding, padding, padding, padding);

        TextView tapCount = text(column, R.id.tap_count, "Taps: 0");
        TextView lastItem = text(column, R.id.last_item, "Last item: none");
        button(column, R.id.tap_button, "Tap me", view -> tapCount.setText("Taps: " + (++taps)));

        EditText name = new EditText(this);
        name.setId(R.id.name_field);
        name.setHint("Your name");
        name.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        column.addView(name);
        TextView greeting = text(column, R.id.greeting, "No greeting yet");
        button(column, R.id.greet_button, "Greet", view -> greeting.setText("Hello, " + name.getText() + "!"));

        Switch notifications = new Switch(this);
        notifications.setId(R.id.notifications_switch);
        notifications.setText("Notifications");
        column.addView(notifications);

        TextView volume = text(column, R.id.volume_value, "Volume: 50");
        SeekBar slider = new SeekBar(this);
        slider.setId(R.id.volume_slider);
        slider.setContentDescription("Volume");
        slider.setMax(100);
        slider.setProgress(50);
        slider.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override
            public void onProgressChanged(SeekBar bar, int value, boolean fromUser) {
                volume.setText("Volume: " + (Math.round(value / 10f) * 10));
            }

            @Override
            public void onStartTrackingTouch(SeekBar bar) {}

            @Override
            public void onStopTrackingTouch(SeekBar bar) {}
        });
        column.addView(slider);

        TextView longPressCount = text(column, R.id.long_press_count, "Long presses: 0");
        TextView hold = text(column, R.id.hold_target, "Hold me");
        hold.setPadding(0, padding, 0, padding);
        hold.setOnLongClickListener(view -> {
            longPressCount.setText("Long presses: " + (++longPresses));
            return true;
        });

        TextView swipeCount = text(column, R.id.swipe_count, "Swipes: 0");
        TextView swipe = text(column, R.id.swipe_target, "Swipe me sideways");
        swipe.setPadding(0, padding * 2, 0, padding * 2);
        swipe.setOnTouchListener((view, event) -> {
            if (event.getAction() == MotionEvent.ACTION_DOWN) touchStartX = event.getX();
            if (event.getAction() == MotionEvent.ACTION_UP && Math.abs(event.getX() - touchStartX) > 100) {
                swipeCount.setText("Swipes: " + (++swipes));
            }
            return true;
        });

        button(column, R.id.details_button, "Details", view -> startActivity(new Intent(this, DetailActivity.class)));
        button(column, R.id.alert_button, "Show alert", view -> new AlertDialog.Builder(this)
            .setTitle("Hello from the fixture")
            .setPositiveButton("OK", null)
            .show());

        for (int index = 1; index <= 40; index++) {
            String label = "Item " + index;
            button(column, View.NO_ID, label, view -> lastItem.setText("Last item: " + label));
        }

        ScrollView scroll = new ScrollView(this);
        scroll.setId(R.id.list);
        scroll.addView(column);
        setContentView(scroll);
        setTitle("Harness Fixture");
    }

    private TextView text(LinearLayout parent, int id, String value) {
        TextView view = new TextView(this);
        view.setId(id);
        view.setText(value);
        view.setTextSize(18);
        parent.addView(view);
        return view;
    }

    private void button(LinearLayout parent, int id, String label, View.OnClickListener action) {
        Button button = new Button(this);
        if (id != View.NO_ID) button.setId(id);
        button.setText(label);
        button.setOnClickListener(action);
        parent.addView(button);
    }
}
