package io.github.therogue76.harnessfixture;

import android.app.Activity;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.TextView;

/** A second screen to open and go back from. */
public class DetailActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        TextView title = new TextView(this);
        title.setId(R.id.detail_title);
        title.setText("Detail screen");
        title.setTextSize(24);
        title.setGravity(Gravity.CENTER);
        setContentView(title);
        setTitle("Details");
    }
}
