package videoloop.launcher;

import android.Manifest;
import android.app.Activity;
import android.app.AlarmManager;
import android.app.AlertDialog;
import android.app.PendingIntent;
import android.app.ProgressDialog;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.media.MediaMetadataRetriever;
import android.media.MediaPlayer;
import android.net.Uri;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.IBinder;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.DisplayMetrics;
import android.util.Log;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.SeekBar;
import android.widget.TextView;
import android.widget.Toast;
import android.widget.VideoView;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Minimal kiosk video looper for a digital photo frame.
 *
 *  - Plays a local video endlessly, fullscreen, screen kept on. Looping is
 *    driven by a watchdog, because some decoders (e.g. Allwinner CedarX) ignore
 *    MediaPlayer.setLooping and fire onCompletion at most once. At the end of a
 *    clip it goes back to the start in the smoothest way this decoder allows,
 *    learnt on the first loops: it wraps by itself (Rockchip: left alone), seekTo(0)
 *    works, or only a reload works (Allwinner CedarX). A reload rebuilds the surface,
 *    which shows black, so the video's first frame covers the screen until it plays. The watchdog
 *    keeps running while menus/dialogs are open, so they never stop playback.
 *    Every (re)start is logged under the "VideoLoop" tag so tools can verify it.
 *  - Registered as the HOME launcher (via HomeAlias) so it boots straight in.
 *  - Recovers by itself: GuardService (own process) restarts VideoLoop when the video
 *    stops advancing, and reboots the frame if that keeps failing (a wedged decoder);
 *    a crash restarts the app instead of leaving Android's error dialog on screen.
 *    Both, and periodic stats, go to <storage>/.videoloop/health.log.
 *  - When a memory card or USB stick is mounted, offers to copy its videos into
 *    local storage (<primary storage>/VideoLoop). Never deletes from the card.
 *  - Two-finger press-and-hold (~1.5s) opens a hidden admin menu.
 *  - Revert restores whatever home screen the frame had before, as recorded by
 *    the installer in STATE_FILE. Does NOT touch Wi-Fi.
 */
public class MainActivity extends Activity {

    private static final String TAG = "VideoLoop";
    private static final String PKG = "videoloop.launcher";
    private static final String HOME_ALIAS = PKG + ".HomeAlias";
    private static final String PREFS = "videoloop";
    private static final String KEY_VIDEO = "video_path";
    private static final String KEY_ROTATION = "rotation";
    private static final String KEY_BRIGHTNESS = "brightness";   // 0-255; default max
    private static final String KEY_CRASHES = "recent_crashes";  // wall-clock ms, comma-separated
    private static final int BRIGHTNESS_MAX = 255;

    private static final int CLASH_OVERWRITE = 0;
    private static final int CLASH_KEEP_BOTH = 1;
    private static final int CLASH_SKIP = 2;

    private static final String[] ROTATION_LABELS = {
        "Auto (follow how the frame stands)",
        "Landscape",
        "Portrait",
        "Landscape, upside down",
        "Portrait, upside down"
    };
    private static final int[] ROTATION_MODES = {
        ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR,
        ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE,
        ActivityInfo.SCREEN_ORIENTATION_PORTRAIT,
        ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE,
        ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
    };
    private static final String IMPORT_DIR = "VideoLoop";
    private static final int REQ_STORAGE = 1;

    // Remote/test hooks: adb shell am start -n videoloop.launcher/.MainActivity -a <action>
    private static final String ACTION_SHOW_MENU = PKG + ".SHOW_MENU";
    private static final String ACTION_SHOW_NETWORK = PKG + ".SHOW_NETWORK";
    private static final String ACTION_SHOW_IMPORT = PKG + ".SHOW_IMPORT";
    private static final String ACTION_SET_ROTATION = PKG + ".SET_ROTATION";  // --ei mode <0-4>
    private static final String ACTION_PLAY = PKG + ".PLAY";                  // --es path <file>
    private static final String ACTION_REVERT = PKG + ".REVERT";              // --es confirm yes
    private static final String ACTION_TEST_CRASH = PKG + ".TEST_CRASH";      // checks crash restart

    // Played (relative to primary storage) until a video is chosen in the menu.
    private static final String[] DEFAULTS = { "loop.mp4", "VideoLoop/loop.mp4", "Download/loop.mp4" };

    private static final String[] VIDEO_EXT = {
        ".mp4", ".m4v", ".mkv", ".mov", ".avi", ".webm", ".3gp", ".ts", ".flv"
    };

    // Written by the installer (key=value lines): method=disable|preferred|chooser
    // and original_home=<pkg/.Activity>. The older Frameo-only file is still honoured.
    private static final String STATE_FILE = ".videoloop/state";
    private static final String LEGACY_HOME_FILE = ".videoloop/frameo_home";
    // The frame's name, set by the installer (people often have several frames).
    private static final String NAME_FILE = ".videoloop/name";

    // Filesystems that removable cards / USB sticks show up as, across Android versions.
    private static final String REMOVABLE_FS =
        "vfat|exfat|ntfs|fuseblk|texfat|sdfat|fuse|sdcardfs|esdfs";
    private static final String LRM = String.valueOf((char) 0x200E);  // left-to-right mark
    private static final long HOLD_MS = 1500;
    private static final long WATCHDOG_MS = 500;
    private static final long PREPARE_TIMEOUT_MS = 8000;
    private static final int STALL_TICKS = 4;      // ~2s without progress = frozen
    // Without the overlay permission there's no button out of Android Settings, so come back on our own.
    private static final long SETTINGS_TIMEOUT_MS = 5 * 60 * 1000;

    private VideoView video;
    private final Handler handler = new Handler();
    private Runnable pendingMenu;
    private boolean menuOpen;
    private boolean resumed;
    private boolean preparing;
    private long prepareStartedAt;
    private int lastPos = -1;
    private int stallTicks;
    // How this decoder loops: not known yet; wraps by itself (setLooping honoured:
    // leave the end alone); stops at the end but seekTo(0) works; or only a reload works.
    private static final int LOOP_UNKNOWN = 0, LOOP_NATIVE = 1, LOOP_SEEK = 2, LOOP_RELOAD = 3;
    private int loopMode = LOOP_UNKNOWN;
    private boolean wrapCheck;     // last tick saw a jump back to the start: confirm it plays on
    private boolean justRewound;   // the next jump back to 0 is ours, not the decoder's
    private int seekCheckTicks;    // after our seekTo(0): ticks left to see playback move on
    private ImageView cover;       // the video's first frame, shown over a reload's black frame
    // Health: what GuardService watches, and counters for health.log.
    private static final String HEARTBEAT = "heartbeat";
    private static final String HEALTH_LOG = ".videoloop/health.log";
    private static final long HEARTBEAT_MS = 5000, STATS_MS = 10 * 60 * 1000;
    private boolean hasVideo;      // something to play (else the guard has nothing to expect)
    private long progressAt;       // elapsedRealtime of the last sign the video is advancing
    private long heartbeatAt, statsAt;
    private int nLoops, nPlays;
    private String coverPath;      // which video the cover belongs to

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        video = new VideoView(this);
        // VideoView sizes itself to the video's aspect ratio; centre it on black
        // so portrait or landscape videos get even bars instead of hugging a corner.
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        root.addView(video, new FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT,
            Gravity.CENTER));
        cover = new ImageView(this);
        cover.setScaleType(ImageView.ScaleType.FIT_CENTER);
        cover.setVisibility(View.GONE);
        root.addView(cover, new FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        setContentView(root);
        hideSystemUi();

        video.setOnPreparedListener(new MediaPlayer.OnPreparedListener() {
            @Override public void onPrepared(MediaPlayer mp) {
                mp.setLooping(true);   // honored on some decoders; watchdog covers the rest
                preparing = false;
                video.start();
                // The first frame is up shortly after start(); then drop the cover.
                handler.postDelayed(hideCover, 300);
            }
        });
        video.setOnCompletionListener(new MediaPlayer.OnCompletionListener() {
            @Override public void onCompletion(MediaPlayer mp) {
                // A decoder that loops by itself never completes.
                if (loopMode != LOOP_NATIVE) loopMode = LOOP_SEEK;
                rewind();
            }
        });
        video.setOnErrorListener(new MediaPlayer.OnErrorListener() {
            @Override public boolean onError(MediaPlayer mp, int what, int extra) {
                preparing = true;
                prepareStartedAt = SystemClock.uptimeMillis();
                handler.postDelayed(new Runnable() {
                    @Override public void run() { play(); }
                }, 1500);
                return true;
            }
        });

        applyRotation();
        applyBrightness(savedBrightness());   // default max; slider overrides and is remembered

        IntentFilter cardFilter = new IntentFilter(Intent.ACTION_MEDIA_MOUNTED);
        cardFilter.addDataScheme("file");
        registerReceiver(cardReceiver, cardFilter);

        // Android 6+ asks for storage access at runtime. The installer normally
        // pre-grants it over adb; otherwise ask once on the frame.
        if (Build.VERSION.SDK_INT >= 23
                && checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE)
                   != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{
                Manifest.permission.READ_EXTERNAL_STORAGE,
                Manifest.permission.WRITE_EXTERNAL_STORAGE}, REQ_STORAGE);
        }

        installCrashRestart();
        progressAt = SystemClock.elapsedRealtime();
        statsAt = progressAt;
        health(this, "start VideoLoop " + versionName());
        startService(new Intent(this, GuardService.class));

        play();
        handler.postDelayed(watchdog, 1000);
        handleIntent(getIntent());
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        if (requestCode == REQ_STORAGE) {
            preparing = false;
            play();
        }
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handleIntent(intent);
    }

    private void handleIntent(Intent intent) {
        if (intent == null || intent.getAction() == null) return;
        String a = intent.getAction();
        if (ACTION_SHOW_MENU.equals(a)) showAdminMenu();
        else if (ACTION_SHOW_NETWORK.equals(a)) showScreenInfo();
        else if (ACTION_SHOW_IMPORT.equals(a)) offerImport(null);
        else if (ACTION_SET_ROTATION.equals(a)) setRotation(intent.getIntExtra("mode", 0));
        else if (ACTION_PLAY.equals(a)) {
            String path = intent.getStringExtra("path");
            if (path != null && new File(path).isFile()) setVideo(path);
            else Log.w(TAG, "PLAY: no such file " + path);
        }
        else if (ACTION_TEST_CRASH.equals(a)) {
            throw new RuntimeException("test crash (" + ACTION_TEST_CRASH + ")");
        }
        else if (ACTION_REVERT.equals(a) && "yes".equals(intent.getStringExtra("confirm"))) {
            revertNextBoot(false);   // same safety checks as the menu item
        }
    }

    @Override
    protected void onDestroy() {
        try { unregisterReceiver(cardReceiver); } catch (Exception e) { /* not registered */ }
        handler.removeCallbacksAndMessages(null);
        super.onDestroy();
    }

    // ---------------- playback ----------------

    private void play() {
        String path = currentVideo();
        hasVideo = path != null;
        if (path == null) { preparing = false; Log.w(TAG, "no video to play"); return; }
        Log.i(TAG, "play " + path);
        nPlays++;
        preparing = true;
        prepareStartedAt = SystemClock.uptimeMillis();
        lastPos = -1;
        stallTicks = 0;
        wrapCheck = false;
        seekCheckTicks = 0;
        loadCover(path);
        video.setVideoURI(Uri.fromFile(new File(path)));
        video.start();
    }

    /**
     * Back to the start without reloading: seekTo(0) keeps the surface, so no black
     * frame. If the decoder doesn't resume, the stall check falls back to restart().
     */
    private void rewind() {
        if (preparing || seekCheckTicks > 0) return;   // one seek at a time
        if (loopMode == LOOP_RELOAD) { reloadCovered(); return; }
        try {
            Log.i(TAG, "loop (seek)");
            nLoops++;
            video.seekTo(0);
            video.start();
            justRewound = true;
            stallTicks = 0;
            seekCheckTicks = 2;
        } catch (Exception e) {
            restart();
        }
    }

    /** The end of a loop on a decoder that can only reload: hide the black behind the first frame. */
    private void reloadCovered() {
        if (preparing) return;
        if (coverPath != null && coverPath.equals(currentVideo()) && cover.getDrawable() != null) {
            handler.removeCallbacks(hideCover);
            cover.setVisibility(View.VISIBLE);
        }
        int pos = -1, dur = -1;
        try { pos = video.getCurrentPosition(); dur = video.getDuration(); } catch (Exception e) { /* ignore */ }
        Log.i(TAG, "loop (reload) at " + pos + "/" + dur + " ms");
        nLoops++;
        restart();
    }

    private final Runnable hideCover = new Runnable() {
        @Override public void run() { cover.setVisibility(View.GONE); }
    };

    /** Grab the video's first frame in the background, once per video. */
    private void loadCover(final String path) {
        if (path.equals(coverPath)) return;
        coverPath = path;
        cover.setImageDrawable(null);
        new Thread(new Runnable() {
            @Override public void run() {
                MediaMetadataRetriever r = new MediaMetadataRetriever();
                try {
                    r.setDataSource(path);
                    final Bitmap b = r.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC);
                    handler.post(new Runnable() {
                        @Override public void run() { if (path.equals(coverPath)) cover.setImageBitmap(b); }
                    });
                } catch (Exception e) {
                    Log.w(TAG, "no cover frame: " + e);
                } finally {
                    try { r.release(); } catch (Exception e) { /* ignore */ }
                }
            }
        }).start();
    }

    /** Restart playback from scratch (debounced), deferred off any callback. Flashes black. */
    private void restart() {
        if (preparing) return;
        preparing = true;
        prepareStartedAt = SystemClock.uptimeMillis();
        handler.post(new Runnable() { @Override public void run() { play(); } });
    }

    /**
     * Drives the endless loop: restarts at end-of-clip, when playback freezes,
     * or when a prepare hangs. Runs regardless of open menus/dialogs.
     */
    private final Runnable watchdog = new Runnable() {
        @Override public void run() {
            long delay = WATCHDOG_MS;
            if (resumed && video != null) {
                if (preparing) {
                    if (SystemClock.uptimeMillis() - prepareStartedAt > PREPARE_TIMEOUT_MS) {
                        preparing = false;
                        play();
                    }
                } else {
                    try {
                        int dur = video.getDuration();
                        int pos = video.getCurrentPosition();
                        boolean jumpedBack = lastPos > 0 && pos + 1000 < lastPos;
                        if (seekCheckTicks > 0) {
                            // Our seekTo(0): did playback carry on from the start?
                            if (lastPos >= 0 && pos > lastPos && pos < dur - 250) {
                                seekCheckTicks = 0;
                                if (loopMode != LOOP_NATIVE) loopMode = LOOP_SEEK;
                            } else if (--seekCheckTicks == 0) {
                                // It didn't (Allwinner CedarX near the end): reload from now on.
                                Log.i(TAG, "seek doesn't restart this decoder; reloading instead");
                                loopMode = LOOP_RELOAD;
                                reloadCovered();
                            }
                        } else if (wrapCheck) {
                            // Last tick the position went back to the start. A decoder that
                            // loops plays on from there; one that stopped (and just reports
                            // 0) doesn't.
                            wrapCheck = false;
                            if (pos > lastPos) {
                                loopMode = LOOP_NATIVE;
                                Log.i(TAG, "loop (native)");
                                nLoops++;
                                stallTicks = 0;
                            } else {
                                rewind();
                            }
                        } else if (jumpedBack) {
                            if (loopMode == LOOP_NATIVE) {
                                Log.i(TAG, "loop (native)");
                                nLoops++;
                                stallTicks = 0;
                            } else {
                                wrapCheck = true;
                            }
                        } else if (dur > 500 && pos >= dur - 250) {
                            if (loopMode == LOOP_SEEK || loopMode == LOOP_RELOAD) rewind();
                            else if (pos == lastPos) rewind();   // stopped at the end
                            // LOOP_NATIVE / not yet known and still moving: let it wrap.
                        } else if (pos == lastPos) {
                            if (++stallTicks >= STALL_TICKS) restart();
                        } else {
                            stallTicks = 0;
                        }
                        if (lastPos >= 0 && pos > lastPos) progressAt = SystemClock.elapsedRealtime();
                        lastPos = justRewound ? -1 : pos;
                        justRewound = false;
                        // A decoder that stops at the end: wake ~50 ms before it, so the
                        // seek/reload lands as the last frame shows (a miss just holds it).
                        if ((loopMode == LOOP_SEEK || loopMode == LOOP_RELOAD) && dur > 500
                                && seekCheckTicks == 0 && !preparing) {
                            int left = dur - pos;
                            if (left > 0 && left < WATCHDOG_MS + 250) delay = Math.max(20, left - 50);
                        }
                    } catch (Exception e) { /* ignore */ }
                }
            }
            tickHealth();
            handler.postDelayed(this, delay);
        }
    };

    /** Heartbeat for GuardService every few seconds, stats to health.log every 10 min. */
    private void tickHealth() {
        long now = SystemClock.elapsedRealtime();
        // Only the instance in front speaks for VideoLoop: other instances (an older
        // task, the direct MainActivity launch) are paused and said so in onPause.
        if (resumed && now - heartbeatAt >= HEARTBEAT_MS) {
            heartbeatAt = now;
            writeHeartbeat(hasVideo);
        }
        if (now - statsAt >= STATS_MS) {
            statsAt = now;
            String[] fds = new File("/proc/self/fd").list();
            String[] tasks = new File("/proc/self/task").list();
            health(this, "stats loops=" + nLoops + " plays=" + nPlays + " mode=" + loopMode
                + " fds=" + (fds == null ? -1 : fds.length) + " threads=" + (tasks == null ? -1 : tasks.length)
                + " heapKB=" + (Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory()) / 1024
                + " nativeKB=" + android.os.Debug.getNativeHeapAllocatedSize() / 1024);
        }
    }

    private void writeHeartbeat(boolean playing) {
        try {
            FileWriter w = new FileWriter(new File(getFilesDir(), HEARTBEAT));
            w.write(android.os.Process.myPid() + " " + (playing ? 1 : 0) + " " + progressAt + "\n");
            w.close();
        } catch (Exception e) { /* best effort */ }
    }

    /** Appends a timestamped line to <storage>/.videoloop/health.log (kept under ~256 KB). */
    static void health(Context c, String line) {
        try {
            File f = new File(localRoot(), HEALTH_LOG);
            f.getParentFile().mkdirs();
            if (f.length() > 256 * 1024) f.renameTo(new File(f.getPath() + ".1"));
            FileWriter w = new FileWriter(f, true);
            w.write(new java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(new java.util.Date())
                    + " [" + android.os.Process.myPid() + "] " + line + "\n");
            w.close();
        } catch (Throwable e) {
            Log.w(TAG, "health log: " + e);
        }
        Log.i(TAG, "health: " + line);
    }

    /** Back to VideoLoop the way the frame does it: through HOME, so no extra instance. */
    static Intent homeIntent() {
        Intent i = new Intent(Intent.ACTION_MAIN);
        i.addCategory(Intent.CATEGORY_HOME);
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        return i;
    }

    private String versionName() {
        try { return getPackageManager().getPackageInfo(PKG, 0).versionName; } catch (Exception e) { return "?"; }
    }

    /**
     * An uncaught exception would leave Android's "VideoLoop has stopped" dialog on a
     * screen nobody may touch for days. Log it and come back in a moment instead.
     */
    private void installCrashRestart() {
        final Context app = getApplicationContext();
        Thread.setDefaultUncaughtExceptionHandler(new Thread.UncaughtExceptionHandler() {
            @Override public void uncaughtException(Thread t, Throwable e) {
                try {
                    String trace = Log.getStackTraceString(e);
                    health(app, "crash: " + (trace.length() > 1500 ? trace.substring(0, 1500) : trace).replace('\n', '|'));
                    // A crash on startup would loop: after 3 within a minute, stop coming
                    // back by ourselves and leave it to GuardService (once a minute).
                    SharedPreferences p = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
                    long now = System.currentTimeMillis();
                    StringBuilder recent = new StringBuilder();
                    int n = 0;
                    for (String c : p.getString(KEY_CRASHES, "").split(",")) {
                        try { if (now - Long.parseLong(c) < 60000) { recent.append(c).append(','); n++; } }
                        catch (Exception ignored) { /* empty or junk */ }
                    }
                    p.edit().putString(KEY_CRASHES, recent.toString() + now).commit();
                    if (n < 3) {
                        PendingIntent pi = PendingIntent.getActivity(app, 0, homeIntent(), PendingIntent.FLAG_ONE_SHOT);
                        ((AlarmManager) app.getSystemService(Context.ALARM_SERVICE))
                            .set(AlarmManager.ELAPSED_REALTIME, SystemClock.elapsedRealtime() + 1500, pi);
                    } else {
                        health(app, "crash: 3+ in a minute; not restarting by ourselves, the guard will");
                    }
                } catch (Throwable ignored) { /* nothing more we can do */ }
                android.os.Process.killProcess(android.os.Process.myPid());
                System.exit(10);
            }
        });
    }

    private String currentVideo() {
        SharedPreferences p = getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String saved = p.getString(KEY_VIDEO, null);
        if (saved != null && new File(saved).exists()) return saved;
        for (String d : DEFAULTS) {
            File f = new File(localRoot(), d);
            if (f.exists()) return f.getPath();
        }
        List<String> found = localVideos();
        return found.isEmpty() ? null : found.get(0);
    }

    private void setVideo(String path) {
        getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY_VIDEO, path).apply();
        preparing = false;
        play();
    }

    // ---------------- hidden gesture: two-finger hold ----------------

    @Override
    public boolean dispatchTouchEvent(MotionEvent ev) {
        int action = ev.getActionMasked();
        if (!menuOpen) {
            if (ev.getPointerCount() >= 2
                    && (action == MotionEvent.ACTION_POINTER_DOWN
                        || action == MotionEvent.ACTION_DOWN)) {
                scheduleMenu();
            } else if (action == MotionEvent.ACTION_UP
                    || action == MotionEvent.ACTION_POINTER_UP
                    || action == MotionEvent.ACTION_CANCEL) {
                cancelMenu();
            }
        }
        return super.dispatchTouchEvent(ev);
    }

    private void scheduleMenu() {
        cancelMenu();
        pendingMenu = new Runnable() {
            @Override public void run() { showAdminMenu(); }
        };
        handler.postDelayed(pendingMenu, HOLD_MS);
    }

    private void cancelMenu() {
        if (pendingMenu != null) {
            handler.removeCallbacks(pendingMenu);
            pendingMenu = null;
        }
    }

    private final DialogInterface.OnDismissListener menuDismissed =
        new DialogInterface.OnDismissListener() {
            @Override public void onDismiss(DialogInterface dlg) {
                menuOpen = false;
                hideSystemUi();
            }
        };

    // ---------------- admin menu ----------------

    private void showAdminMenu() {
        menuOpen = true;
        final String[] items = {
            "Choose video…",
            "Import videos from memory card…",
            "Screen rotation…",
            "Brightness…",
            "Screen & network info",
            "Open Android Settings (Wi-Fi, etc.)",
            "Restore original home screen on next reboot",
            "Switch to original home screen now",
            "Reboot now",
            "Cancel"
        };
        new AlertDialog.Builder(this)
            .setTitle(frameName() != null ? LRM + "VideoLoop — " + frameName() : "VideoLoop")
            .setItems(items, new DialogInterface.OnClickListener() {
                @Override public void onClick(DialogInterface dlg, int which) {
                    switch (which) {
                        case 0: chooseVideo();         break;
                        case 1: offerImport(null);     break;
                        case 2: chooseRotation();      break;
                        case 3: chooseBrightness();    break;
                        case 4: showScreenInfo();      break;
                        case 5: openSettings();        break;
                        case 6: revertNextBoot(false); break;
                        case 7: revertNextBoot(true);  break;
                        case 8: rebootNow();           break;
                        default: /* cancel */          break;
                    }
                }
            })
            .setOnDismissListener(menuDismissed)
            .show();
    }

    // ---------------- screen rotation ----------------
    // Portrait videos need the screen turned, not the file: "Auto" follows the
    // frame's accelerometer, so standing the frame on its side shows portrait.

    private int rotationIndex() {
        int i = getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt(KEY_ROTATION, 0);
        return (i >= 0 && i < ROTATION_MODES.length) ? i : 0;
    }

    private void applyRotation() {
        setRequestedOrientation(ROTATION_MODES[rotationIndex()]);
    }

    private void setRotation(int index) {
        if (index < 0 || index >= ROTATION_MODES.length) return;
        getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putInt(KEY_ROTATION, index).apply();
        applyRotation();
    }

    private void chooseRotation() {
        menuOpen = true;
        new AlertDialog.Builder(this)
            .setTitle("Screen rotation")
            .setSingleChoiceItems(ROTATION_LABELS, rotationIndex(), new DialogInterface.OnClickListener() {
                @Override public void onClick(DialogInterface dlg, int which) {
                    setRotation(which);
                    dlg.dismiss();
                }
            })
            .setOnDismissListener(menuDismissed)
            .show();
    }

    // ---------------- network info ----------------

    /** The frame's name from the installer, or null if none was set. */
    private String frameName() {
        String n = firstLine(new File(localRoot(), NAME_FILE).getPath());
        if (n == null) return null;
        n = n.trim();
        return n.length() == 0 ? null : n;
    }

    /** The panel's native pixel size, largest dimension first (e.g. "1280 × 800"). */
    private String nativeResolution() {
        try {
            DisplayMetrics dm = new DisplayMetrics();
            getWindowManager().getDefaultDisplay().getRealMetrics(dm);
            int hi = Math.max(dm.widthPixels, dm.heightPixels);
            int lo = Math.min(dm.widthPixels, dm.heightPixels);
            return hi + " × " + lo;
        } catch (Exception e) {
            return "unknown";
        }
    }

    private void showScreenInfo() {
        String ip = ipAddress();
        String mac = macAddress();
        String name = frameName();
        String res = nativeResolution();
        menuOpen = true;
        new AlertDialog.Builder(this)
            .setTitle("Screen & network info")
            .setMessage((name != null ? "Frame:\n" + name + "\n\n" : "")
                        + "Screen size (native):\n" + res + " px"
                        + "\nUse a video this size (H.264 .mp4) for the sharpest fit."
                        + "\n\nIP address:\n" + (ip != null ? ip : "unknown (not connected?)")
                        + "\n\nMAC address:\n" + mac
                        + "\n(some frames pick a new MAC on every reboot,"
                        + " so the IP can change after a reboot)"
                        + (ip != null ? "\n\nADB: adb connect " + ip + ":5555" : ""))
            .setPositiveButton("OK", null)
            .setOnDismissListener(menuDismissed)
            .show();
    }

    // ---------------- brightness ----------------
    // The frame's stock Settings app crashes on its brightness slider on some
    // units, so VideoLoop sets it directly: live on this window, and persisted
    // system-wide (via Settings.System, falling back to root where that needs
    // the WRITE_SETTINGS permission the frame won't grant).

    private void chooseBrightness() {
        menuOpen = true;
        final SeekBar bar = new SeekBar(this);
        bar.setMax(BRIGHTNESS_MAX);
        bar.setProgress(savedBrightness());
        int pad = (int) (24 * getResources().getDisplayMetrics().density);
        bar.setPadding(pad, pad, pad, pad);
        bar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar sb, int v, boolean fromUser) {
                if (fromUser) setBrightness(Math.max(8, v));     // never fully dark; remembered
            }
            @Override public void onStartTrackingTouch(SeekBar sb) { }
            @Override public void onStopTrackingTouch(SeekBar sb) { }
        });
        new AlertDialog.Builder(this)
            .setTitle("Brightness")
            .setView(bar)
            .setPositiveButton("OK", null)
            .setOnDismissListener(menuDismissed)
            .show();
    }

    /** Remembered brightness, defaulting to max so a fresh frame comes up bright. */
    private int savedBrightness() {
        int b = getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt(KEY_BRIGHTNESS, BRIGHTNESS_MAX);
        return (b < 8) ? 8 : (b > BRIGHTNESS_MAX ? BRIGHTNESS_MAX : b);
    }

    /** Remember the user's choice, then apply it. */
    private void setBrightness(int b) {
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putInt(KEY_BRIGHTNESS, b).apply();
        applyBrightness(b);
    }

    private void applyBrightness(int b) {
        // Immediate feedback on this window (works without any permission).
        try {
            WindowManager.LayoutParams lp = getWindow().getAttributes();
            lp.screenBrightness = b / 255f;
            getWindow().setAttributes(lp);
        } catch (Exception e) { /* ignore */ }
        // Persist system-wide so it survives / affects the whole frame.
        boolean ok = false;
        try {
            Settings.System.putInt(getContentResolver(),
                Settings.System.SCREEN_BRIGHTNESS_MODE, 0);      // manual
            Settings.System.putInt(getContentResolver(),
                Settings.System.SCREEN_BRIGHTNESS, b);
            ok = true;
        } catch (Exception e) { ok = false; }
        if (!ok) runSu("settings put system screen_brightness_mode 0 ; "
                       + "settings put system screen_brightness " + b);
    }

    /** IPv4 of the active interface, or null. */
    private String ipAddress() {
        try {
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (ni.isLoopback() || !ni.isUp()) continue;
                for (InetAddress a : Collections.list(ni.getInetAddresses())) {
                    if (a instanceof Inet4Address) return a.getHostAddress();
                }
            }
        } catch (Exception e) { /* fall through */ }
        try {
            WifiManager wm = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            int ip = wm.getConnectionInfo().getIpAddress();
            if (ip != 0) {
                return String.format(Locale.US, "%d.%d.%d.%d",
                    ip & 0xff, (ip >> 8) & 0xff, (ip >> 16) & 0xff, (ip >> 24) & 0xff);
            }
        } catch (Exception e) { /* fall through */ }
        String line = runSuRead("ip -4 addr show wlan0");
        if (line != null) {
            Matcher m = Pattern.compile("inet (\\d+\\.\\d+\\.\\d+\\.\\d+)").matcher(line);
            if (m.find()) return m.group(1);
        }
        return null;
    }

    private String macAddress() {
        String[] ifaces = {"wlan0", "eth0", "wlan1"};
        for (String i : ifaces) {
            String m = firstLine("/sys/class/net/" + i + "/address");
            if (m != null) m = m.trim();
            if (m != null && m.length() == 17 && !m.equals("00:00:00:00:00:00")) {
                return m + "  (" + i + ")";
            }
        }
        String m = runSuRead("cat /sys/class/net/wlan0/address");
        if (m != null && m.trim().length() == 17) return m.trim() + "  (wlan0)";
        return "unknown";
    }

    private String firstLine(String path) {
        try {
            BufferedReader r = new BufferedReader(new FileReader(path));
            String line = r.readLine();
            r.close();
            return line;
        } catch (Exception e) {
            return null;
        }
    }

    // ---------------- choose video (local storage) ----------------

    private void chooseVideo() {
        final List<String> vids = localVideos();
        if (vids.isEmpty()) {
            toast("No videos in local storage.\nImport some from a memory card first.");
            return;
        }
        String current = normalize(currentVideo());
        final String[] labels = new String[vids.size()];
        for (int i = 0; i < vids.size(); i++) {
            String v = vids.get(i);
            labels[i] = LRM + (v.equals(current) ? "▶ " : "    ") + shorten(v);
        }
        menuOpen = true;
        new AlertDialog.Builder(this)
            .setTitle("Choose video")
            .setItems(labels, new DialogInterface.OnClickListener() {
                @Override public void onClick(DialogInterface dlg, int which) {
                    setVideo(vids.get(which));
                    toast("Now looping: " + shorten(vids.get(which)));
                }
            })
            .setOnDismissListener(menuDismissed)
            .show();
    }

    private List<String> localVideos() {
        List<String> out = new ArrayList<String>();
        scan(localRoot(), out, 0);
        Collections.sort(out);
        return out;
    }

    /** The frame's own storage (/storage/emulated/0, /mnt/sdcard, /storage/sdcard0, ...). */
    private static File localRoot() {
        return Environment.getExternalStorageDirectory();
    }

    private static String canonical(File f) {
        try { return f.getCanonicalPath(); } catch (Exception e) { return f.getAbsolutePath(); }
    }

    /**
     * Mounted memory cards and USB sticks. Paths differ a lot between frames
     * (/storage/XXXX-XXXX, /mnt/extsd, /mnt/usbhost1, ...), so combine what is
     * actually mounted with /storage/*. (Context.getExternalFilesDirs would also
     * list volumes, but it creates folders on the card, and the card is the
     * user's, so it is deliberately not used.)
     */
    private List<File> removableRoots() {
        String primary = canonical(localRoot());
        List<File> out = new ArrayList<File>();
        List<String> seen = new ArrayList<String>();
        for (String mp : removableMountPoints()) addRoot(out, seen, new File(mp), primary);
        File[] kids = new File("/storage").listFiles();
        if (kids != null) for (File k : kids) addRoot(out, seen, k, primary);
        return out;
    }

    private static void addRoot(List<File> out, List<String> seen, File f, String primary) {
        if (f == null || !f.isDirectory() || !f.canRead() || f.listFiles() == null) return;
        String n = f.getName();
        if (n.equals("emulated") || n.equals("self") || n.equals("sdcard0") || n.equals("legacy")) return;
        String c = canonical(f);
        if (c.equals(primary) || c.startsWith(primary + "/") || primary.startsWith(c + "/")) return;
        if (seen.contains(c)) return;
        seen.add(c);
        out.add(f);
    }

    /** Mount points under /storage or /mnt with a removable-media filesystem. */
    private static List<String> removableMountPoints() {
        List<String> out = new ArrayList<String>();
        try {
            BufferedReader r = new BufferedReader(new FileReader("/proc/mounts"));
            String line;
            while ((line = r.readLine()) != null) {
                String[] p = line.split(" ");
                if (p.length < 3) continue;
                String mp = p[1].replace("\\040", " ");
                if (!(mp.startsWith("/storage/") || mp.startsWith("/mnt/"))) continue;
                if (mp.contains("emulated") || mp.startsWith("/mnt/runtime") || mp.startsWith("/mnt/user")
                        || mp.startsWith("/mnt/asec") || mp.startsWith("/mnt/obb")
                        || mp.startsWith("/mnt/secure") || mp.startsWith("/mnt/expand")) continue;
                if (p[2].matches(REMOVABLE_FS)) out.add(mp);
            }
            r.close();
        } catch (Exception e) { /* fall back to the other sources */ }
        return out;
    }

    private void scan(File dir, List<String> out, int depth) {
        if (dir == null || depth > 5 || out.size() >= 300) return;
        String name = dir.getName();
        if ("Android".equals(name) || "LOST.DIR".equals(name)) return;
        File[] files = dir.listFiles();
        if (files == null) return;
        for (File f : files) {
            if (out.size() >= 300) return;
            if (f.isDirectory()) {
                scan(f, out, depth + 1);
            } else {
                String lower = f.getName().toLowerCase(Locale.US);
                if (lower.startsWith(".")) continue;
                for (String ext : VIDEO_EXT) {
                    if (lower.endsWith(ext)) { out.add(f.getAbsolutePath()); break; }
                }
            }
        }
    }

    private String shorten(String path) {
        String root = localRoot().getPath();
        String p = path;
        if (p.startsWith(root + "/")) p = p.substring(root.length() + 1);
        else if (p.startsWith("/storage/")) p = p.substring("/storage/".length());
        else if (p.startsWith("/mnt/")) p = p.substring("/mnt/".length());
        return p;
    }

    /** /sdcard/... and the primary storage path are the same file; compare one form. */
    private static String normalize(String path) {
        if (path != null && path.startsWith("/sdcard/")) {
            return localRoot().getPath() + path.substring("/sdcard".length());
        }
        return path;
    }

    /** Path relative to whichever card root it lives under. */
    private static String relativeTo(List<File> roots, String path) {
        for (File r : roots) {
            String prefix = r.getPath() + "/";
            if (path.startsWith(prefix)) return path.substring(prefix.length());
        }
        return path;
    }

    // ---------------- memory card import ----------------

    private final BroadcastReceiver cardReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            Uri d = i.getData();
            final String path = d == null ? null : d.getPath();
            if (path == null) return;
            String mounted = canonical(new File(path));
            String primary = canonical(localRoot());
            if (mounted.equals(primary) || path.startsWith("/storage/emulated")
                    || path.startsWith("/storage/self")) return;
            // Give the FUSE view a moment to come up before scanning.
            handler.postDelayed(new Runnable() {
                @Override public void run() { offerImport(path); }
            }, 1500);
        }
    };

    /** Shows the card's videos (all pre-selected) and copies the chosen ones. */
    private void offerImport(String cardPath) {
        List<File> roots = new ArrayList<File>();
        if (cardPath != null) roots.add(new File(cardPath));
        else roots.addAll(removableRoots());
        if (roots.isEmpty()) {
            toast("No memory card or USB stick found.");
            return;
        }
        final List<String> vids = new ArrayList<String>();
        for (File r : roots) scan(r, vids, 0);
        Collections.sort(vids);
        if (vids.isEmpty()) {
            toast("No videos on the memory card / USB stick.");
            return;
        }
        final String[] labels = new String[vids.size()];
        final boolean[] checked = new boolean[vids.size()];
        for (int i = 0; i < vids.size(); i++) {
            File f = new File(vids.get(i));
            // LRM marks keep Hebrew/RTL filenames from swapping the size to the wrong side.
            labels[i] = LRM + relativeTo(roots, vids.get(i)) + LRM + "  (" + mb(f.length()) + ")";
            checked[i] = true;
        }
        menuOpen = true;
        new AlertDialog.Builder(this)
            .setTitle("Card / USB: " + vids.size() + " video(s)")
            .setMultiChoiceItems(labels, checked, new DialogInterface.OnMultiChoiceClickListener() {
                @Override public void onClick(DialogInterface dlg, int which, boolean isChecked) {
                    checked[which] = isChecked;
                }
            })
            .setPositiveButton("Copy to frame", new DialogInterface.OnClickListener() {
                @Override public void onClick(DialogInterface dlg, int w) {
                    List<File> picked = new ArrayList<File>();
                    for (int i = 0; i < vids.size(); i++) {
                        if (checked[i]) picked.add(new File(vids.get(i)));
                    }
                    if (picked.isEmpty()) { toast("Nothing selected."); return; }
                    final List<File> sel = picked;
                    handler.post(new Runnable() {
                        @Override public void run() { resolveClashesThenCopy(sel); }
                    });
                }
            })
            .setNegativeButton("Cancel", null)
            .setOnDismissListener(menuDismissed)
            .show();
    }

    private File importDir() {
        return new File(Environment.getExternalStorageDirectory(), IMPORT_DIR);
    }

    /** If any picked name already exists on the frame, ask: overwrite, keep both, or skip. */
    private void resolveClashesThenCopy(final List<File> files) {
        File destDir = importDir();
        List<File> clashes = new ArrayList<File>();
        for (File f : files) if (new File(destDir, f.getName()).exists()) clashes.add(f);
        if (clashes.isEmpty()) { copyToLocal(files, CLASH_SKIP); return; }

        StringBuilder msg = new StringBuilder(clashes.size() == 1
            ? "A video with this name is already on the frame:\n\n"
            : "Videos with these names are already on the frame:\n\n");
        for (File f : clashes) {
            File existing = new File(destDir, f.getName());
            msg.append(LRM).append("- ").append(f.getName()).append(LRM);
            if (existing.length() == f.length()) msg.append("  (same size)");
            else msg.append("  (card ").append(mb(f.length()))
                    .append(", frame ").append(mb(existing.length())).append(")");
            msg.append('\n');
        }
        msg.append("\nOverwrite replaces the frame's copy with the card's.")
           .append("\nKeep both saves the card's copy under a new name.");
        menuOpen = true;
        new AlertDialog.Builder(this)
            .setTitle("Already on the frame")
            .setMessage(msg.toString())
            .setPositiveButton("Overwrite", clashChoice(files, CLASH_OVERWRITE))
            .setNeutralButton("Keep both", clashChoice(files, CLASH_KEEP_BOTH))
            .setNegativeButton("Skip", clashChoice(files, CLASH_SKIP))
            .setOnDismissListener(menuDismissed)
            .show();
    }

    private DialogInterface.OnClickListener clashChoice(final List<File> files, final int mode) {
        return new DialogInterface.OnClickListener() {
            @Override public void onClick(DialogInterface dlg, int w) {
                handler.post(new Runnable() {
                    @Override public void run() { copyToLocal(files, mode); }
                });
            }
        };
    }

    /**
     * Copies files into /sdcard/VideoLoop on a background thread, with progress.
     * Name clashes are handled per {@code clashMode}. Each file is written to a
     * .part first, so an existing file is only replaced by a complete copy.
     */
    private void copyToLocal(final List<File> files, final int clashMode) {
        final File destDir = importDir();
        long total = 0;
        for (File f : files) total += f.length();
        final long totalBytes = Math.max(total, 1);

        destDir.mkdirs();
        if (destDir.getUsableSpace() < total) {
            toast("Not enough space on the frame: need " + mb(total)
                  + ", have " + mb(destDir.getUsableSpace()) + ".");
            return;
        }

        final ProgressDialog pd = new ProgressDialog(this);
        pd.setTitle("Copying videos to the frame");
        pd.setProgressStyle(ProgressDialog.STYLE_HORIZONTAL);
        pd.setMax(100);
        pd.setCancelable(false);
        pd.setMessage("Starting…");
        menuOpen = true;
        pd.show();

        new Thread(new Runnable() {
            @Override public void run() {
                int copied = 0, replaced = 0, skipped = 0, failed = 0;
                final List<String> replacedPaths = new ArrayList<String>();
                long done = 0;
                byte[] buf = new byte[256 * 1024];
                for (final File src : files) {
                    File target = targetFor(destDir, src, clashMode);
                    if (target == null) { skipped++; done += src.length(); continue; }
                    boolean replacing = target.exists();
                    final String name = src.getName();
                    runOnUiThread(new Runnable() {
                        @Override public void run() { pd.setMessage(name); }
                    });
                    File part = new File(target.getPath() + ".part");
                    boolean ok = false;
                    InputStream in = null;
                    FileOutputStream out = null;
                    try {
                        in = new FileInputStream(src);
                        out = new FileOutputStream(part);
                        int n;
                        int lastPct = -1;
                        while ((n = in.read(buf)) > 0) {
                            out.write(buf, 0, n);
                            done += n;
                            final int pct = (int) (done * 100 / totalBytes);
                            if (pct != lastPct) {
                                lastPct = pct;
                                runOnUiThread(new Runnable() {
                                    @Override public void run() { pd.setProgress(pct); }
                                });
                            }
                        }
                        out.getFD().sync();
                        ok = true;
                    } catch (Exception e) {
                        ok = false;
                    } finally {
                        try { if (in != null) in.close(); } catch (Exception e) { /* ignore */ }
                        try { if (out != null) out.close(); } catch (Exception e) { /* ignore */ }
                    }
                    if (!ok) {
                        // Fallback for storage the app can't read directly.
                        ok = runSu("cp " + shellQuote(src.getPath()) + " " + shellQuote(part.getPath()));
                    }
                    boolean placed = ok && part.length() == src.length() && part.renameTo(target);
                    if (!placed && ok && replacing && part.length() == src.length()) {
                        // rename() normally replaces in place; if not, swap in the complete copy.
                        placed = target.delete() && part.renameTo(target);
                    }
                    if (placed) {
                        if (replacing) { replaced++; replacedPaths.add(target.getPath()); }
                        else copied++;
                    } else {
                        part.delete();
                        failed++;
                    }
                }
                final int c = copied, r = replaced, s = skipped, f = failed;
                runOnUiThread(new Runnable() {
                    @Override public void run() {
                        pd.dismiss();
                        // If the playing video was replaced, switch to the new copy.
                        if (replacedPaths.contains(normalize(currentVideo()))) {
                            preparing = false;
                            play();
                        }
                        showImportResult(c, r, s, f);
                    }
                });
            }
        }).start();
    }

    private void showImportResult(int copied, int replaced, int skipped, int failed) {
        StringBuilder msg = new StringBuilder();
        msg.append("Copied: ").append(copied);
        if (replaced > 0) msg.append("\nOverwritten: ").append(replaced);
        if (skipped > 0) msg.append("\nSkipped (already on the frame): ").append(skipped);
        if (failed > 0) msg.append("\nFailed: ").append(failed);
        msg.append("\n\nSaved to: ").append(IMPORT_DIR).append("/");
        msg.append("\nThe memory card was not changed.");
        menuOpen = true;
        new AlertDialog.Builder(this)
            .setTitle("Import finished")
            .setMessage(msg.toString())
            .setPositiveButton("Choose video", new DialogInterface.OnClickListener() {
                @Override public void onClick(DialogInterface dlg, int w) {
                    handler.post(new Runnable() { @Override public void run() { chooseVideo(); } });
                }
            })
            .setNegativeButton("Close", null)
            .setOnDismissListener(menuDismissed)
            .show();
    }

    /**
     * Where to copy src, given how the user chose to handle a name clash:
     * the same path (overwrite), null (skip), or a free " (n)" name (keep both).
     */
    private File targetFor(File dir, File src, int clashMode) {
        File t = new File(dir, src.getName());
        if (!t.exists()) return t;
        if (clashMode == CLASH_OVERWRITE) return t;
        if (clashMode == CLASH_SKIP) return null;
        String name = src.getName();
        int dot = name.lastIndexOf('.');
        String base = dot > 0 ? name.substring(0, dot) : name;
        String ext = dot > 0 ? name.substring(dot) : "";
        for (int i = 1; i < 1000; i++) {
            t = new File(dir, base + " (" + i + ")" + ext);
            if (!t.exists()) return t;
        }
        return null;
    }

    private static String mb(long bytes) {
        return String.format(Locale.US, "%.1f MB", bytes / 1048576.0);
    }

    private static String shellQuote(String s) {
        return "'" + s.replace("'", "'\\''") + "'";
    }

    // ---------------- settings / revert / reboot ----------------

    private void openSettings() {
        // These frames have no navigation bar or HOME key, and some firmware kills the
        // home app's process as Settings opens. So grant the overlay permission now,
        // while we still can, and let BackButtonService (its own process) bring us back.
        if (!canOverlay(this)) runSu("appops set " + PKG + " SYSTEM_ALERT_WINDOW allow");
        try {
            startService(new Intent(this, BackButtonService.class));
            if (!canOverlay(this)) {
                toast("Android Settings will close and the video come back in "
                      + (SETTINGS_TIMEOUT_MS / 60000) + " minutes.");
            }
            Intent i = new Intent(Settings.ACTION_SETTINGS);
            i.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(i);
        } catch (Exception e) {
            stopService(new Intent(this, BackButtonService.class));
            toast("Couldn't open Settings.");
        }
    }

    static boolean canOverlay(Context c) {
        return Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(c);
    }

    /**
     * Watches VideoLoop from its own process (":guard"), so it still works when the
     * main thread is stuck (e.g. in a wedged decoder call). Every 15 s it reads the
     * heartbeat MainActivity writes; if the video should be playing but hasn't
     * advanced for a minute, it kills and relaunches VideoLoop. If that happens
     * MAX_RESTARTS times within 15 minutes, the decoder itself is wedged, so it
     * reboots the frame with root, at most once every 6 hours (a broken video file
     * mustn't become a reboot loop).
     */
    public static class GuardService extends Service {
        private static final long CHECK_MS = 15000, STUCK_MS = 60000;
        private static final long WINDOW_MS = 15 * 60 * 1000, REBOOT_GAP_MS = 6 * 3600 * 1000;
        private static final int MAX_RESTARTS = 3;
        private static final String LAST_REBOOT = "guard_last_reboot";   // wall clock, survives reboots
        private final Handler h = new Handler();
        private final ArrayList<Long> restarts = new ArrayList<Long>();
        private final Runnable check = new Runnable() {
            @Override public void run() { checkOnce(); h.postDelayed(this, CHECK_MS); }
        };

        @Override public IBinder onBind(Intent intent) { return null; }

        @Override
        public int onStartCommand(Intent intent, int flags, int startId) {
            h.removeCallbacks(check);
            h.postDelayed(check, CHECK_MS);
            return START_STICKY;
        }

        private void checkOnce() {
            String[] hb = null;
            try {
                BufferedReader r = new BufferedReader(new FileReader(new File(getFilesDir(), HEARTBEAT)));
                String line = r.readLine();
                r.close();
                if (line != null) hb = line.trim().split(" ");
            } catch (Exception e) { return; }
            if (hb == null || hb.length < 3 || !"1".equals(hb[1])) return;
            long stuck = SystemClock.elapsedRealtime() - Long.parseLong(hb[2]);
            if (stuck < STUCK_MS) return;
            long now = SystemClock.elapsedRealtime();
            while (!restarts.isEmpty() && now - restarts.get(0) > WINDOW_MS) restarts.remove(0);
            if (restarts.size() >= MAX_RESTARTS && rebootAllowed()) {
                health(this, "guard: still no progress after " + restarts.size()
                       + " restarts in 15 min; rebooting the frame");
                getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                    .putLong(LAST_REBOOT, System.currentTimeMillis()).commit();
                try { Runtime.getRuntime().exec(new String[]{"su", "-c", "reboot"}); }
                catch (Exception e) { health(this, "guard: reboot failed: " + e); }
                return;
            }
            restarts.add(now);
            health(this, "guard: video stuck for " + stuck / 1000 + " s; restarting VideoLoop (pid " + hb[0] + ")");
            try {   // mark it fresh so the next check gives the new process its minute
                FileWriter w = new FileWriter(new File(getFilesDir(), HEARTBEAT));
                w.write("0 1 " + now + "\n");
                w.close();
            } catch (Exception e) { /* ignore */ }
            try {
                int pid = Integer.parseInt(hb[0]);
                if (pid > 0 && pid != android.os.Process.myPid()) android.os.Process.killProcess(pid);
            } catch (Exception e) { /* ignore */ }
            h.postDelayed(new Runnable() {
                @Override public void run() { startActivity(homeIntent()); }
            }, 1000);
        }

        private boolean rebootAllowed() {
            long last = getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong(LAST_REBOOT, 0);
            return System.currentTimeMillis() - last > REBOOT_GAP_MS;
        }
    }

    /**
     * Floats a "Back to VideoLoop" button over Android Settings, and returns to the
     * video when it's tapped. Runs in its own process (":back" in the manifest)
     * because some frame firmware kills the home app's process when Settings opens,
     * which would take the button with it. Without the overlay permission it just
     * returns after SETTINGS_TIMEOUT_MS. MainActivity stops it whenever it resumes.
     */
    public static class BackButtonService extends Service {
        private final Handler handler = new Handler();
        private View button;
        private final Runnable back = new Runnable() {
            @Override public void run() { goBack(); }
        };

        @Override public IBinder onBind(Intent intent) { return null; }

        @Override
        public int onStartCommand(Intent intent, int flags, int startId) {
            handler.removeCallbacks(back);
            if (button == null && !show()) {
                Log.w(TAG, "settings: no overlay, returning after a timeout");
                handler.postDelayed(back, SETTINGS_TIMEOUT_MS);
            }
            return START_NOT_STICKY;
        }

        private boolean show() {
            if (!canOverlay(this)) return false;
            float dp = getResources().getDisplayMetrics().density;
            TextView b = new TextView(this);
            b.setText("\u25C0  Back to VideoLoop");
            b.setTextColor(Color.WHITE);
            b.setTextSize(20);
            int pad = (int) (14 * dp);
            b.setPadding(pad + pad / 2, pad, pad + pad / 2, pad);
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(0xCC000000);
            bg.setCornerRadius(28 * dp);
            bg.setStroke((int) (2 * dp), Color.WHITE);
            b.setBackgroundDrawable(bg);
            b.setOnClickListener(new View.OnClickListener() {
                @Override public void onClick(View v) { goBack(); }
            });
            WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
                Build.VERSION.SDK_INT >= 26 ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                                            : WindowManager.LayoutParams.TYPE_PHONE,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                    | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT);
            lp.gravity = Gravity.BOTTOM | Gravity.RIGHT;
            lp.x = (int) (24 * dp);
            lp.y = (int) (24 * dp);
            try {
                ((WindowManager) getSystemService(WINDOW_SERVICE)).addView(b, lp);
                button = b;
                Log.i(TAG, "settings: back button shown");
                return true;
            } catch (Exception e) {
                Log.w(TAG, "settings: back button failed: " + e);
                return false;
            }
        }

        private void goBack() {
            Log.i(TAG, "settings: back to the loop");
            startActivity(homeIntent());
            stopSelf();
        }

        @Override
        public void onDestroy() {
            handler.removeCallbacks(back);
            if (button != null) {
                try { ((WindowManager) getSystemService(WINDOW_SERVICE)).removeView(button); }
                catch (Exception e) { /* already gone */ }
                button = null;
            }
            super.onDestroy();
        }
    }

    /**
     * Give the home screen back to whatever the frame had before VideoLoop.
     * If the installer disabled the original home (root method), re-enable it
     * first. Our own home role is only turned off once another home screen is
     * confirmed to exist, so a failed revert can never leave the frame without one.
     */
    private void revertNextBoot(boolean switchNow) {
        String[] st = readState();          // {method, original_home}
        String method = st[0], original = st[1];
        // original_app.sh may have switched the whole original app off: bring it back
        // first, or its home screen can't come back.
        if (original != null) {
            String pkg = original.split("/")[0];
            if (packageOff(pkg) && (!runSu("pm enable " + pkg) || packageOff(pkg))) {
                toast("Couldn't get root on the frame to turn\n" + pkg
                      + " back on.\nRun revert.sh from your computer instead.");
                return;
            }
        }
        if ("disable".equals(method) && original != null) {
            if (!runSu("pm enable " + original)) {
                toast("Couldn't get root on the frame to re-enable\n" + original
                      + "\nRun revert.sh from your computer instead.");
                return;
            }
        }
        if (!otherHomeExists()) {
            toast("No other home screen is enabled on this frame, so VideoLoop stays.\n"
                  + "Run revert.sh from your computer instead.");
            return;
        }
        Log.i(TAG, "revert: method=" + method + " original=" + original);
        getPackageManager().setComponentEnabledSetting(
            new ComponentName(this, HOME_ALIAS),
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP);

        if (switchNow) {
            Intent home = new Intent(Intent.ACTION_MAIN);
            home.addCategory(Intent.CATEGORY_HOME);
            home.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(home);
            finish();
        } else {
            toast("Done. The next reboot will start the original home screen.\n"
                  + "The video keeps playing until then.");
        }
    }

    private boolean packageOff(String pkg) {
        try {
            int s = getPackageManager().getApplicationEnabledSetting(pkg);
            return s == PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                || s == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER
                || s == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_UNTIL_USED;
        } catch (Exception e) {
            return false;   // not installed: nothing to turn back on
        }
    }

    /** {method, original_home} from the installer's state file (or the older Frameo file). */
    private String[] readState() {
        String method = null, original = null;
        try {
            BufferedReader r = new BufferedReader(new FileReader(new File(localRoot(), STATE_FILE)));
            String line;
            while ((line = r.readLine()) != null) {
                int eq = line.indexOf('=');
                if (eq <= 0) continue;
                String k = line.substring(0, eq).trim(), v = line.substring(eq + 1).trim();
                if (k.equals("method")) method = v;
                else if (k.equals("original_home") && v.length() > 0) original = v;
            }
            r.close();
        } catch (Exception e) {
            String legacy = firstLine(new File(localRoot(), LEGACY_HOME_FILE).getPath());
            if (legacy != null && legacy.trim().length() > 0) {
                method = "disable";
                original = legacy.trim();
            }
        }
        return new String[]{method, original};
    }

    /** True if an enabled HOME activity other than VideoLoop exists. */
    private boolean otherHomeExists() {
        Intent home = new Intent(Intent.ACTION_MAIN);
        home.addCategory(Intent.CATEGORY_HOME);
        List<ResolveInfo> homes = getPackageManager().queryIntentActivities(home, 0);
        if (homes == null) return false;
        for (ResolveInfo ri : homes) {
            if (ri.activityInfo != null && !PKG.equals(ri.activityInfo.packageName)) return true;
        }
        return false;
    }

    private void rebootNow() {
        if (!runSu("reboot")) {
            toast("Couldn't reboot (no on-device root). Use: adb reboot");
        }
    }

    private boolean runSu(String command) {
        Process p = null;
        try {
            p = Runtime.getRuntime().exec(new String[]{"su", "-c", command});
            return p.waitFor() == 0;
        } catch (Exception e) {
            return false;
        } finally {
            if (p != null) p.destroy();
        }
    }

    /** Runs a root command and returns all of its stdout (or null). */
    private String runSuRead(String command) {
        Process p = null;
        try {
            p = Runtime.getRuntime().exec(new String[]{"su", "-c", command});
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null) sb.append(line).append('\n');
            r.close();
            p.waitFor();
            return sb.length() == 0 ? null : sb.toString();
        } catch (Exception e) {
            return null;
        } finally {
            if (p != null) p.destroy();
        }
    }

    private void toast(String msg) {
        Toast.makeText(this, msg, Toast.LENGTH_LONG).show();
    }

    // ---------------- window / lifecycle ----------------

    private void hideSystemUi() {
        video.setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
              | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
              | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
              | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
              | View.SYSTEM_UI_FLAG_FULLSCREEN
              | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus && !menuOpen) hideSystemUi();
    }

    @Override
    protected void onResume() {
        super.onResume();
        resumed = true;
        progressAt = SystemClock.elapsedRealtime();   // give playback a fresh minute
        writeHeartbeat(hasVideo);
        // Back from Android Settings, however we got here: drop the floating button.
        stopService(new Intent(this, BackButtonService.class));
        if (video != null && !video.isPlaying() && !preparing) play();
    }

    @Override
    protected void onPause() {
        resumed = false;
        writeHeartbeat(false);   // paused (menus elsewhere, Android Settings): nothing to guard
        super.onPause();
    }

    @Override
    public void onBackPressed() {
        // Swallow BACK so the kiosk can't be exited by a stray touch.
    }
}
