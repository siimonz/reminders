// showup.jsx
import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  View,
  Text,
  TextInput,
  Pressable,
  Modal,
  FlatList,
  ScrollView,
  KeyboardAvoidingView,
  Platform,
  StatusBar,
  Animated,
  Easing,
  Image,
} from "react-native";

// Optional AsyncStorage (recommended)
let AsyncStorage = null;
try {
  // eslint-disable-next-line global-require
  AsyncStorage = require("@react-native-async-storage/async-storage").default;
} catch (e) {
  AsyncStorage = null;
}

// Optional safe-area-context (recommended)
let SafeAreaViewX = null;
let useSafeAreaInsetsX = null;
try {
  // eslint-disable-next-line global-require
  const s = require("react-native-safe-area-context");
  SafeAreaViewX = s.SafeAreaView;
  useSafeAreaInsetsX = s.useSafeAreaInsets;
} catch (e) {
  SafeAreaViewX = null;
  useSafeAreaInsetsX = null;
}

const T = {
  bg: "#F8F6F2",
  ink: "#1A1A1A",
  sub: "#5C5C5C",
  mut: "#A0A0A0",
  div: "#EAE6DF",
  crd: "#FFFFFF",
  cbd: "#E8E4DD",
  glt: "#E6F7ED",
  grn: "#5BD68B",
  red: "#E5484D",
  rbg: "#FFF0F0",
  f1: "#FF9F43",
  f2: "#54A0FF",
};

const STORE_KEY = "showup_v2_state";

const uid = () => Math.random().toString(16).slice(2) + Date.now().toString(16);

function pad2(n) {
  return String(n).padStart(2, "0");
}
function todayKey(d = new Date()) {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}
function parseDayKey(k) {
  const [y, m, d] = (k || "").split("-").map(Number);
  return new Date(y, (m || 1) - 1, d || 1);
}
function addDays(dayKey, delta) {
  const d = parseDayKey(dayKey);
  d.setDate(d.getDate() + delta);
  return todayKey(d);
}
function daysBetween(a, b) {
  const da = parseDayKey(a);
  const db = parseDayKey(b);
  return Math.round((db - da) / 86400000);
}
function clamp(n, a, b) {
  return Math.max(a, Math.min(b, n));
}

function seededInitialData() {
  const now = Date.now();
  const mk = (o) => ({
    id: uid(),
    kind: "reminder", // "reminder" | "habit"
    title: "",
    body: "",
    tags: [],
    priority: "med", // low|med|high
    source: "Me",
    pinned: false,
    stickyPin: false, // if true: can “hold” spotlight
    topRule: false,
    createdAt: now,
    updatedAt: now,
    snoozeUntil: null, // YYYY-MM-DD
    snoozeCount: 0,
    reflectCount: 0,
    lastShown: null, // YYYY-MM-DD
    lastReflected: null, // YYYY-MM-DD
    ...o,
  });

  return {
    items: [
      mk({
        title: "Don’t negotiate with your bedtime.",
        tags: ["Health", "Mindset"],
        priority: "high",
        source: "Me",
      }),
      mk({
        title: "When stressed, slow down your voice.",
        tags: ["Relationships", "Mindset"],
        priority: "high",
        source: "Wife",
      }),
      mk({
        title: "If it’s not scheduled, it’s a wish.",
        tags: ["Work"],
        priority: "med",
        source: "Mentor",
      }),
      mk({
        kind: "habit",
        title: "Walk 20 minutes",
        tags: ["Health"],
        priority: "med",
        source: "Me",
      }),
      mk({
        kind: "habit",
        title: "Read 10 pages",
        tags: ["Mindset"],
        priority: "low",
        source: "Me",
      }),
    ],
    settings: {
      dailyNudgeEnabled: false, // placeholder (notifications not wired in this single file)
      preferStickyPinned: true,
      topRulesModeEnabled: true,
    },
    daily: {
      dayKey: null,
      spotlightId: null,
      habitIds: [],
    },
  };
}

async function loadState() {
  if (!AsyncStorage) return null;
  try {
    const raw = await AsyncStorage.getItem(STORE_KEY);
    if (!raw) return null;
    return JSON.parse(raw);
  } catch {
    return null;
  }
}
async function saveState(st) {
  if (!AsyncStorage) return;
  try {
    await AsyncStorage.setItem(STORE_KEY, JSON.stringify(st));
  } catch {
    // ignore
  }
}

function normalizeTagsInput(s) {
  if (!s) return [];
  return s
    .split(",")
    .map((t) => t.trim())
    .filter(Boolean)
    .slice(0, 8);
}

function priorityScore(p) {
  if (p === "high") return 3;
  if (p === "med") return 2;
  return 1;
}

function weightFor(item, today) {
  // Lightweight, not creepy: just enough “memory muscle.”
  let w = 1;

  w += priorityScore(item.priority);

  if (item.pinned) w += 6;
  if (item.topRule) w += 4;

  // “If you keep snoozing it, it needs more repetition.”
  w += clamp(item.snoozeCount * 0.6, 0, 3);

  // Recency dampener (avoid showing the same thing too often unless pinned/sticky)
  if (item.lastShown) {
    const d = daysBetween(item.lastShown, today);
    if (d <= 0) w *= 0.1;
    else if (d === 1) w *= 0.35;
    else if (d === 2) w *= 0.65;
    else if (d === 3) w *= 0.8;
  }

  // If recently reflected, slightly reduce (unless pinned/topRule)
  if (item.lastReflected && !item.pinned && !item.topRule) {
    const r = daysBetween(item.lastReflected, today);
    if (r === 0) w *= 0.25;
    else if (r === 1) w *= 0.6;
  }

  return Math.max(0.05, w);
}

function pickWeighted(items) {
  const total = items.reduce((s, it) => s + it._w, 0);
  let r = Math.random() * total;
  for (const it of items) {
    r -= it._w;
    if (r <= 0) return it;
  }
  return items[items.length - 1];
}

function computeDailyPicks(allItems, settings, dayKeyStr) {
  const reminders = allItems.filter((x) => x.kind === "reminder");
  const habits = allItems.filter((x) => x.kind === "habit");

  const eligible = reminders.filter((x) => {
    if (!x.title?.trim() && !x.body?.trim()) return false;
    if (x.snoozeUntil && daysBetween(dayKeyStr, x.snoozeUntil) > 0) return false; // today < snoozeUntil
    return true;
  });

  // Sticky pinned: if user has "hold spotlight" pins, show one until unpinned (optional behavior)
  if (settings?.preferStickyPinned) {
    const stickies = eligible
      .filter((x) => x.pinned && x.stickyPin)
      .sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
    if (stickies.length) {
      return {
        spotlightId: stickies[0].id,
        habitIds: computeHabitPicks(habits, dayKeyStr),
      };
    }
  }

  const weighted = eligible.map((x) => ({ ...x, _w: weightFor(x, dayKeyStr) }));
  const spotlight = weighted.length ? pickWeighted(weighted) : null;

  return {
    spotlightId: spotlight?.id || null,
    habitIds: computeHabitPicks(habits, dayKeyStr),
  };
}

function computeHabitPicks(habits, dayKeyStr) {
  const eligible = habits.filter((h) => h.title?.trim());
  if (!eligible.length) return [];

  // Show up to 3 habit prompts/day, rotate by recency
  const scored = eligible
    .map((h) => {
      let s = 1 + priorityScore(h.priority) * 0.5;
      if (h.lastShown) {
        const d = daysBetween(h.lastShown, dayKeyStr);
        if (d <= 0) s *= 0.1;
        else if (d === 1) s *= 0.55;
        else if (d === 2) s *= 0.8;
      }
      return { ...h, _w: s };
    })
    .sort((a, b) => b._w - a._w);

  // Pick 1–3 depending on how many they have
  const n = clamp(scored.length, 1, 3);
  const picks = [];
  const pool = [...scored];
  while (picks.length < n && pool.length) {
    const p = pickWeighted(pool);
    picks.push(p.id);
    const idx = pool.findIndex((x) => x.id === p.id);
    if (idx >= 0) pool.splice(idx, 1);
  }
  return picks;
}

function useDebouncedEffect(fn, deps, ms = 200) {
  const t = useRef(null);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (t.current) clearTimeout(t.current);
    t.current = setTimeout(fn, ms);
    return () => {
      if (t.current) clearTimeout(t.current);
    };
  }, deps);
}

function Chip({ label, active, onPress }) {
  return (
    <Pressable
      onPress={onPress}
      style={{
        paddingHorizontal: 12,
        paddingVertical: 8,
        borderRadius: 999,
        backgroundColor: active ? T.ink : T.crd,
        borderWidth: 1,
        borderColor: active ? T.ink : T.cbd,
        marginRight: 8,
      }}
    >
      <Text style={{ color: active ? T.crd : T.ink, fontSize: 13, fontWeight: "600" }}>
        {label}
      </Text>
    </Pressable>
  );
}

function IconButton({ label, tone = "neutral", onPress }) {
  const bg =
    tone === "primary" ? T.ink : tone === "good" ? T.glt : tone === "bad" ? T.rbg : T.crd;
  const fg =
    tone === "primary" ? T.crd : tone === "good" ? T.ink : tone === "bad" ? T.red : T.ink;
  const bd =
    tone === "primary" ? T.ink : tone === "good" ? "#D5F0E0" : tone === "bad" ? "#F7C7C7" : T.cbd;

  return (
    <Pressable
      onPress={onPress}
      style={{
        flexDirection: "row",
        alignItems: "center",
        paddingHorizontal: 12,
        paddingVertical: 10,
        borderRadius: 14,
        backgroundColor: bg,
        borderWidth: 1,
        borderColor: bd,
      }}
    >
      <Text style={{ color: fg, fontSize: 13, fontWeight: "700" }}>{label}</Text>
    </Pressable>
  );
}

function FloatingAction({ onPress }) {
  return (
    <Pressable
      onPress={onPress}
      style={{
        position: "absolute",
        right: 16,
        bottom: 80,
        backgroundColor: T.ink,
        borderRadius: 999,
        paddingHorizontal: 16,
        paddingVertical: 14,
        shadowColor: "#000",
        shadowOpacity: 0.18,
        shadowRadius: 14,
        shadowOffset: { width: 0, height: 10 },
        elevation: 8,
      }}
    >
      <Text style={{ color: T.crd, fontWeight: "800", fontSize: 14 }}>＋ Capture</Text>
    </Pressable>
  );
}

function SoftDivider() {
  return <View style={{ height: 1, backgroundColor: T.div, marginVertical: 12 }} />;
}

function PriorityPill({ p }) {
  const meta =
    p === "high"
      ? { bg: "#FFF4E8", bd: "#FFE1C2", fg: "#7A3E00", dot: T.f1 }
      : p === "med"
      ? { bg: "#EEF6FF", bd: "#D6E9FF", fg: "#003A6B", dot: T.f2 }
      : { bg: "#F3F3F3", bd: "#E6E6E6", fg: "#4A4A4A", dot: T.mut };

  return (
    <View
      style={{
        flexDirection: "row",
        alignItems: "center",
        paddingHorizontal: 10,
        paddingVertical: 6,
        borderRadius: 999,
        backgroundColor: meta.bg,
        borderWidth: 1,
        borderColor: meta.bd,
      }}
    >
      <View
        style={{
          width: 7,
          height: 7,
          borderRadius: 999,
          backgroundColor: meta.dot,
          marginRight: 7,
        }}
      />
      <Text style={{ color: meta.fg, fontSize: 12, fontWeight: "700" }}>
        {p === "high" ? "High" : p === "med" ? "Med" : "Low"}
      </Text>
    </View>
  );
}

function ReflectPulse({ trigger }) {
  const v = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    if (!trigger) return;
    v.setValue(0);
    Animated.sequence([
      Animated.timing(v, { toValue: 1, duration: 220, easing: Easing.out(Easing.cubic), useNativeDriver: true }),
      Animated.timing(v, { toValue: 0, duration: 350, easing: Easing.inOut(Easing.cubic), useNativeDriver: true }),
    ]).start();
  }, [trigger, v]);

  const scale = v.interpolate({ inputRange: [0, 1], outputRange: [0.9, 1.06] });
  const opacity = v.interpolate({ inputRange: [0, 1], outputRange: [0, 1] });

  return (
    <Animated.View
      pointerEvents="none"
      style={{
        position: "absolute",
        top: -8,
        right: -8,
        opacity,
        transform: [{ scale }],
      }}
    >
      <View
        style={{
          backgroundColor: T.glt,
          borderColor: "#D5F0E0",
          borderWidth: 1,
          paddingHorizontal: 10,
          paddingVertical: 6,
          borderRadius: 999,
        }}
      >
        <Text style={{ fontWeight: "900", color: T.ink }}>✓ Nice.</Text>
      </View>
    </Animated.View>
  );
}

function TopTabs({ tab, setTab }) {
  const tabs = [
    { k: "home", label: "Spotlight" },
    { k: "library", label: "Library" },
    { k: "habits", label: "Habits" },
  ];

  return (
    <View
      style={{
        flexDirection: "row",
        paddingHorizontal: 14,
        paddingVertical: 10,
        borderTopWidth: 1,
        borderTopColor: T.div,
        backgroundColor: T.bg,
      }}
    >
      {tabs.map((t) => {
        const active = tab === t.k;
        return (
          <Pressable
            key={t.k}
            onPress={() => setTab(t.k)}
            style={{ flex: 1, alignItems: "center", paddingVertical: 10, borderRadius: 14 }}
          >
            <Text style={{ color: active ? T.ink : T.mut, fontWeight: active ? "800" : "700" }}>
              {t.label}
            </Text>
          </Pressable>
        );
      })}
    </View>
  );
}

function Sheet({ visible, onClose, children }) {
  return (
    <Modal transparent visible={visible} animationType="fade" onRequestClose={onClose}>
      <Pressable onPress={onClose} style={{ flex: 1, backgroundColor: "rgba(0,0,0,0.35)" }}>
        <Pressable
          onPress={() => {}}
          style={{
            marginTop: "auto",
            backgroundColor: T.bg,
            borderTopLeftRadius: 26,
            borderTopRightRadius: 26,
            borderWidth: 1,
            borderColor: "rgba(255,255,255,0.25)",
            paddingTop: 10,
            paddingBottom: 18,
          }}
        >
          <View style={{ alignItems: "center", paddingBottom: 10 }}>
            <View style={{ width: 46, height: 5, borderRadius: 999, backgroundColor: "#D9D5CE" }} />
          </View>
          {children}
        </Pressable>
      </Pressable>
    </Modal>
  );
}

function Segmented({ value, onChange, options }) {
  return (
    <View style={{ flexDirection: "row", backgroundColor: T.crd, borderRadius: 16, borderWidth: 1, borderColor: T.cbd }}>
      {options.map((o) => {
        const active = value === o.value;
        return (
          <Pressable
            key={o.value}
            onPress={() => onChange(o.value)}
            style={{
              flex: 1,
              paddingVertical: 10,
              alignItems: "center",
              borderRadius: 14,
              backgroundColor: active ? T.ink : "transparent",
            }}
          >
            <Text style={{ color: active ? T.crd : T.ink, fontWeight: "800", fontSize: 13 }}>{o.label}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}

function ReminderCard({ item, onOpen, rightBadge }) {
  const title = item.title?.trim();
  const body = item.body?.trim();
  return (
    <Pressable
      onPress={onOpen}
      style={{
        backgroundColor: T.crd,
        borderRadius: 22,
        borderWidth: 1,
        borderColor: T.cbd,
        padding: 16,
        marginBottom: 12,
        shadowColor: "#000",
        shadowOpacity: 0.06,
        shadowRadius: 10,
        shadowOffset: { width: 0, height: 6 },
        elevation: 2,
      }}
    >
      <View style={{ flexDirection: "row", alignItems: "flex-start" }}>
        <View style={{ flex: 1, paddingRight: 10 }}>
          {!!title && (
            <Text style={{ color: T.ink, fontSize: 16, fontWeight: "900", lineHeight: 21 }}>
              {title}
            </Text>
          )}
          {!!body && (
            <Text style={{ color: T.sub, marginTop: title ? 8 : 0, lineHeight: 20 }}>
              {body.length > 120 ? body.slice(0, 120) + "…" : body}
            </Text>
          )}
          <View style={{ flexDirection: "row", alignItems: "center", marginTop: 12, flexWrap: "wrap" }}>
            <PriorityPill p={item.priority} />
            <View style={{ width: 8 }} />
            {item.source && item.source !== "Me" ? (
              <Text style={{ color: T.mut, fontWeight: "700", fontSize: 12 }}>
                From {item.source}
              </Text>
            ) : null}
            {item.pinned ? (
              <Text style={{ color: T.ink, fontWeight: "900", marginLeft: 10 }}>★</Text>
            ) : null}
            {item.topRule ? (
              <Text style={{ color: T.ink, fontWeight: "900", marginLeft: 10 }}>✦</Text>
            ) : null}
          </View>
        </View>
        {rightBadge ? rightBadge : null}
      </View>

      {!!item.tags?.length ? (
        <View style={{ flexDirection: "row", flexWrap: "wrap", marginTop: 12 }}>
          {item.tags.slice(0, 5).map((t) => (
            <View
              key={t}
              style={{
                paddingHorizontal: 10,
                paddingVertical: 6,
                borderRadius: 999,
                backgroundColor: "#F3F1ED",
                borderWidth: 1,
                borderColor: "#E6E2DB",
                marginRight: 8,
                marginBottom: 8,
              }}
            >
              <Text style={{ color: T.sub, fontWeight: "700", fontSize: 12 }}>{t}</Text>
            </View>
          ))}
        </View>
      ) : null}
    </Pressable>
  );
}

function DetailSheet({
  visible,
  onClose,
  item,
  onEdit,
  onTogglePin,
  onToggleTopRule,
  onSnooze,
  onDelete,
}) {
  if (!item) return null;
  const title = item.title?.trim();
  const body = item.body?.trim();

  return (
    <Sheet visible={visible} onClose={onClose}>
      <ScrollView contentContainerStyle={{ paddingHorizontal: 16 }}>
        <Text style={{ color: T.mut, fontWeight: "800", marginBottom: 10 }}>
          {item.kind === "habit" ? "Habit reminder" : "Reminder"}
        </Text>

        {!!title && (
          <Text style={{ color: T.ink, fontSize: 22, fontWeight: "950", lineHeight: 28 }}>
            {title}
          </Text>
        )}
        {!!body && (
          <Text style={{ color: T.sub, marginTop: 12, fontSize: 15.5, lineHeight: 22 }}>
            {body}
          </Text>
        )}

        <View style={{ flexDirection: "row", alignItems: "center", marginTop: 14, flexWrap: "wrap" }}>
          <PriorityPill p={item.priority} />
          {item.source && item.source !== "Me" ? (
            <>
              <View style={{ width: 10 }} />
              <Text style={{ color: T.mut, fontWeight: "800" }}>From {item.source}</Text>
            </>
          ) : null}
        </View>

        {!!item.tags?.length ? (
          <View style={{ flexDirection: "row", flexWrap: "wrap", marginTop: 14 }}>
            {item.tags.map((t) => (
              <View
                key={t}
                style={{
                  paddingHorizontal: 10,
                  paddingVertical: 6,
                  borderRadius: 999,
                  backgroundColor: "#F3F1ED",
                  borderWidth: 1,
                  borderColor: "#E6E2DB",
                  marginRight: 8,
                  marginBottom: 8,
                }}
              >
                <Text style={{ color: T.sub, fontWeight: "800", fontSize: 12 }}>{t}</Text>
              </View>
            ))}
          </View>
        ) : null}

        <SoftDivider />

        <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 10 }}>
          <IconButton label={item.pinned ? "Unpin ★" : "Pin ★"} onPress={onTogglePin} tone="neutral" />
          {item.kind === "reminder" ? (
            <IconButton
              label={item.topRule ? "Remove from Top 3 ✦" : "Add to Top 3 ✦"}
              onPress={onToggleTopRule}
              tone={item.topRule ? "primary" : "neutral"}
            />
          ) : null}
        </View>

        <SoftDivider />

        <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 10 }}>
          {item.kind === "reminder" ? (
            <IconButton label="Snooze 1 day" onPress={() => onSnooze(1)} tone="neutral" />
          ) : null}
          <IconButton label="Edit" onPress={onEdit} tone="primary" />
          <IconButton label="Delete" onPress={onDelete} tone="bad" />
        </View>

        <View style={{ height: 24 }} />
      </ScrollView>
    </Sheet>
  );
}

function ComposerSheet({ visible, onClose, initial, onSave }) {
  const [kind, setKind] = useState(initial?.kind || "reminder");
  const [title, setTitle] = useState(initial?.title || "");
  const [body, setBody] = useState(initial?.body || "");
  const [tagsText, setTagsText] = useState((initial?.tags || []).join(", "));
  const [priority, setPriority] = useState(initial?.priority || "med");
  const [source, setSource] = useState(initial?.source || "Me");
  const [showDetails, setShowDetails] = useState(false);

  useEffect(() => {
    if (!visible) return;
    setKind(initial?.kind || "reminder");
    setTitle(initial?.title || "");
    setBody(initial?.body || "");
    setTagsText((initial?.tags || []).join(", "));
    setPriority(initial?.priority || "med");
    setSource(initial?.source || "Me");
    setShowDetails(!!(initial?.body?.trim() || initial?.tags?.length || (initial?.source && initial.source !== "Me")));
  }, [visible, initial]);

  const templates = useMemo(
    () => [
      { label: "Rule: ___", apply: () => setTitle((t) => (t ? t : "Rule: ")) },
      { label: "Remember: ___", apply: () => setTitle((t) => (t ? t : "Remember: ")) },
      { label: "If ___ then ___", apply: () => setTitle((t) => (t ? t : "If  then "))) },
    ],
    []
  );

  const canSave = (title.trim().length > 0) || (body.trim().length > 0);

  return (
    <Sheet visible={visible} onClose={onClose}>
      <KeyboardAvoidingView behavior={Platform.OS === "ios" ? "padding" : undefined}>
        <ScrollView contentContainerStyle={{ paddingHorizontal: 16 }}>
          <Text style={{ color: T.mut, fontWeight: "900", marginBottom: 10 }}>
            {initial?.id ? "Edit" : "Capture a thought"}
          </Text>

          <Segmented
            value={kind}
            onChange={setKind}
            options={[
              { value: "reminder", label: "Reminder" },
              { value: "habit", label: "Habit reminder" },
            ]}
          />

          <View style={{ height: 12 }} />

          <View
            style={{
              backgroundColor: T.crd,
              borderRadius: 22,
              borderWidth: 1,
              borderColor: T.cbd,
              padding: 14,
            }}
          >
            <TextInput
              placeholder="A truth you don't want to forget…"
              placeholderTextColor={T.mut}
              value={title}
              onChangeText={setTitle}
              style={{
                color: T.ink,
                fontSize: 17,
                fontWeight: "900",
                paddingVertical: 8,
              }}
              returnKeyType="next"
            />
          </View>

          <View style={{ height: 10 }} />

          <Pressable
            onPress={() => setShowDetails((v) => !v)}
            style={{ flexDirection: "row", alignItems: "center", paddingVertical: 6 }}
          >
            <Text style={{ color: T.sub, fontWeight: "900", fontSize: 13 }}>
              {showDetails ? "▾ Hide details" : "▸ Add details (body, tags, priority…)"}
            </Text>
          </Pressable>

          {showDetails ? (
            <>
              <View style={{ height: 8 }} />

              <View
                style={{
                  backgroundColor: T.crd,
                  borderRadius: 18,
                  borderWidth: 1,
                  borderColor: T.cbd,
                  padding: 14,
                }}
              >
                <TextInput
                  placeholder="Optional body… (keep it one sentence if you can)"
                  placeholderTextColor={T.mut}
                  value={body}
                  onChangeText={setBody}
                  multiline
                  style={{
                    color: T.sub,
                    fontSize: 15,
                    lineHeight: 21,
                    minHeight: 72,
                    paddingVertical: 8,
                  }}
                />
              </View>

              <View style={{ height: 12 }} />

              <View style={{ flexDirection: "row", alignItems: "center", gap: 10 }}>
                <View style={{ flex: 1 }}>
                  <Text style={{ color: T.mut, fontWeight: "900", marginBottom: 8 }}>Priority</Text>
                  <Segmented
                    value={priority}
                    onChange={setPriority}
                    options={[
                      { value: "low", label: "Low" },
                      { value: "med", label: "Med" },
                      { value: "high", label: "High" },
                    ]}
                  />
                </View>
              </View>

              <View style={{ height: 12 }} />

              <View style={{ flexDirection: "row", gap: 12 }}>
                <View style={{ flex: 1 }}>
                  <Text style={{ color: T.mut, fontWeight: "900", marginBottom: 8 }}>From someone</Text>
                  <View
                    style={{
                      backgroundColor: T.crd,
                      borderRadius: 18,
                      borderWidth: 1,
                      borderColor: T.cbd,
                      paddingHorizontal: 12,
                      paddingVertical: 10,
                    }}
                  >
                    <TextInput
                      value={source}
                      onChangeText={setSource}
                      placeholder="Wife / Coach / Friend / Me…"
                      placeholderTextColor={T.mut}
                      style={{ color: T.ink, fontWeight: "800" }}
                    />
                  </View>
                </View>
              </View>

              <View style={{ height: 12 }} />

              <Text style={{ color: T.mut, fontWeight: "900", marginBottom: 8 }}>Tags (comma-separated)</Text>
              <View
                style={{
                  backgroundColor: T.crd,
                  borderRadius: 18,
                  borderWidth: 1,
                  borderColor: T.cbd,
                  paddingHorizontal: 12,
                  paddingVertical: 10,
                }}
              >
                <TextInput
                  value={tagsText}
                  onChangeText={setTagsText}
                  placeholder="Relationships, Health, Money…"
                  placeholderTextColor={T.mut}
                  style={{ color: T.ink, fontWeight: "800" }}
                />
              </View>

              <View style={{ height: 12 }} />

              <Text style={{ color: T.mut, fontWeight: "900", marginBottom: 8 }}>Quick templates</Text>
              <ScrollView horizontal showsHorizontalScrollIndicator={false}>
                {templates.map((t) => (
                  <Chip key={t.label} label={t.label} active={false} onPress={t.apply} />
                ))}
              </ScrollView>
            </>
          ) : null}

          <View style={{ height: 16 }} />

          <View style={{ flexDirection: "row", gap: 10 }}>
            <View style={{ flex: 1 }}>
              <IconButton label="Cancel" onPress={onClose} tone="neutral" />
            </View>
            <View style={{ flex: 1 }}>
              <IconButton
                label={initial?.id ? "Save" : "Add"}
                onPress={() => {
                  if (!canSave) return;
                  onSave({
                    ...initial,
                    kind,
                    title: title.trim(),
                    body: body.trim(),
                    tags: normalizeTagsInput(tagsText),
                    priority,
                    source: (source || "Me").trim(),
                  });
                }}
                tone={canSave ? "primary" : "neutral"}
              />
            </View>
          </View>

          <View style={{ height: 24 }} />
        </ScrollView>
      </KeyboardAvoidingView>
    </Sheet>
  );
}

function Header({ title, subtitle, right }) {
  return (
    <View style={{ paddingHorizontal: 16, paddingTop: 14, paddingBottom: 10 }}>
      <Text style={{ color: T.ink, fontSize: 26, fontWeight: "950", letterSpacing: -0.2 }}>
        {title}
      </Text>
      {!!subtitle && (
        <Text style={{ color: T.sub, marginTop: 6, fontWeight: "700" }}>
          {subtitle}
        </Text>
      )}
      {right ? <View style={{ marginTop: 10 }}>{right}</View> : null}
    </View>
  );
}

function useSafeInsetsFallback() {
  const insets = useSafeAreaInsetsX ? useSafeAreaInsetsX() : null;
  // fallback: a gentle top pad; iOS safe areas handled by SafeAreaViewX if present
  return insets || { top: Platform.OS === "android" ? StatusBar.currentHeight || 10 : 10, bottom: 10 };
}

export default function App() {
  return <ShowUp />;
}

function ShowUp() {
  const insets = useSafeInsetsFallback();
  const Safe = SafeAreaViewX || View;

  const [tab, setTab] = useState("home");

  const [state, setState] = useState(() => seededInitialData());
  const [ready, setReady] = useState(false);

  const [composerOpen, setComposerOpen] = useState(false);
  const [composerInitial, setComposerInitial] = useState(null);

  const [detailOpen, setDetailOpen] = useState(false);
  const [detailItemId, setDetailItemId] = useState(null);

  const [refPulse, setRefPulse] = useState(0);

  // Load persisted state
  useEffect(() => {
    (async () => {
      const loaded = await loadState();
      if (loaded?.items && loaded?.settings && loaded?.daily) {
        setState(loaded);
      }
      setReady(true);
    })();
  }, []);

  // Persist (debounced)
  useDebouncedEffect(
    () => {
      if (!ready) return;
      saveState(state);
    },
    [state, ready],
    180
  );

  // Ensure daily picks for today
  useEffect(() => {
    if (!ready) return;
    const dk = todayKey();
    if (state.daily?.dayKey === dk) return;

    const picks = computeDailyPicks(state.items, state.settings, dk);

    // mark lastShown for spotlight + habit picks
    const updatedItems = state.items.map((it) => {
      if (it.id === picks.spotlightId) return { ...it, lastShown: dk, updatedAt: Date.now() };
      if (picks.habitIds.includes(it.id)) return { ...it, lastShown: dk, updatedAt: Date.now() };
      return it;
    });

    setState((s) => ({
      ...s,
      items: updatedItems,
      daily: { dayKey: dk, ...picks },
    }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready]);

  const byId = useMemo(() => {
    const m = new Map();
    state.items.forEach((x) => m.set(x.id, x));
    return m;
  }, [state.items]);

  const spotlight = state.daily?.spotlightId ? byId.get(state.daily.spotlightId) : null;

  const openComposer = (initial = null) => {
    setComposerInitial(initial);
    setComposerOpen(true);
  };

  const openDetail = (id) => {
    setDetailItemId(id);
    setDetailOpen(true);
  };

  const upsertItem = (draft) => {
    const now = Date.now();
    if (draft?.id) {
      setState((s) => ({
        ...s,
        items: s.items.map((it) =>
          it.id === draft.id ? { ...it, ...draft, updatedAt: now } : it
        ),
      }));
    } else {
      const n = {
        id: uid(),
        kind: draft.kind || "reminder",
        title: draft.title || "",
        body: draft.body || "",
        tags: draft.tags || [],
        priority: draft.priority || "med",
        source: draft.source || "Me",
        pinned: false,
        stickyPin: false,
        topRule: false,
        createdAt: now,
        updatedAt: now,
        snoozeUntil: null,
        snoozeCount: 0,
        reflectCount: 0,
        lastShown: null,
        lastReflected: null,
      };
      setState((s) => ({ ...s, items: [n, ...s.items] }));
    }
    setComposerOpen(false);
  };

  const togglePin = (id) => {
    setState((s) => ({
      ...s,
      items: s.items.map((it) =>
        it.id === id ? { ...it, pinned: !it.pinned, updatedAt: Date.now() } : it
      ),
    }));
  };

  const toggleStickyPin = (id) => {
    setState((s) => ({
      ...s,
      items: s.items.map((it) =>
        it.id === id ? { ...it, pinned: true, stickyPin: !it.stickyPin, updatedAt: Date.now() } : it
      ),
    }));
  };

  const toggleTopRule = (id) => {
    setState((s) => {
      const it = s.items.find((x) => x.id === id);
      if (!it) return s;

      const currentlyTop = s.items.filter((x) => x.kind === "reminder" && x.topRule);
      // allow max 3
      if (!it.topRule && currentlyTop.length >= 3) {
        // drop the oldest topRule
        const oldest = [...currentlyTop].sort((a, b) => (a.updatedAt || 0) - (b.updatedAt || 0))[0];
        return {
          ...s,
          items: s.items.map((x) => {
            if (x.id === id) return { ...x, topRule: true, updatedAt: Date.now() };
            if (x.id === oldest.id) return { ...x, topRule: false, updatedAt: Date.now() };
            return x;
          }),
        };
      }

      return {
        ...s,
        items: s.items.map((x) => (x.id === id ? { ...x, topRule: !x.topRule, updatedAt: Date.now() } : x)),
      };
    });
  };

  const snooze = (id, days = 1) => {
    const dk = todayKey();
    setState((s) => ({
      ...s,
      items: s.items.map((it) => {
        if (it.id !== id) return it;
        return {
          ...it,
          snoozeUntil: addDays(dk, days),
          snoozeCount: (it.snoozeCount || 0) + 1,
          updatedAt: Date.now(),
        };
      }),
    }));
    // force recompute spotlight next open (but keep daily stable otherwise)
    setState((s) => ({ ...s, daily: { ...s.daily, dayKey: null } }));
  };

  const deleteItem = (id) => {
    setState((s) => ({
      ...s,
      items: s.items.filter((it) => it.id !== id),
      daily: { ...s.daily, dayKey: null },
    }));
    setDetailOpen(false);
  };

  const reflect = (id) => {
    const dk = todayKey();
    setState((s) => ({
      ...s,
      items: s.items.map((it) => {
        if (it.id !== id) return it;
        return {
          ...it,
          reflectCount: (it.reflectCount || 0) + 1,
          lastReflected: dk,
          updatedAt: Date.now(),
        };
      }),
    }));
    setRefPulse((x) => x + 1);
  };

  const content =
    tab === "home" ? (
      <HomeScreen
        spotlight={spotlight}
        onOpen={openDetail}
        onCapture={() => openComposer(null)}
        onQuickAdd={(text) => upsertItem({ title: text })}
        onReflect={() => spotlight?.id && reflect(spotlight.id)}
        onSnooze={() => spotlight?.id && snooze(spotlight.id, 1)}
        onPin={() => spotlight?.id && togglePin(spotlight.id)}
        refPulse={refPulse}
      />
    ) : tab === "library" ? (
      <LibraryScreen
        items={state.items.filter((x) => x.kind === "reminder")}
        onOpen={openDetail}
        onCapture={() => openComposer(null)}
      />
    ) : (
      <HabitsScreen
        items={state.items.filter((x) => x.kind === "habit")}
        onOpen={openDetail}
        onAddHabit={() => openComposer({ kind: "habit", title: "", body: "", tags: [], priority: "med", source: "Me" })}
      />
    );

  const detailItem = detailItemId ? byId.get(detailItemId) : null;

  return (
    <Safe style={{ flex: 1, backgroundColor: T.bg, paddingTop: SafeAreaViewX ? 0 : insets.top }}>
      <StatusBar barStyle="dark-content" />
      <View style={{ flex: 1 }}>
        {content}

        {tab !== "home" ? <FloatingAction onPress={() => openComposer(null)} /> : null}

        <View style={{ position: "absolute", left: 0, right: 0, bottom: 0 }}>
          <TopTabs tab={tab} setTab={setTab} />
        </View>

        <ComposerSheet
          visible={composerOpen}
          onClose={() => setComposerOpen(false)}
          initial={composerInitial}
          onSave={upsertItem}
        />

        <DetailSheet
          visible={detailOpen}
          onClose={() => setDetailOpen(false)}
          item={detailItem}
          onEdit={() => {
            if (!detailItem) return;
            setDetailOpen(false);
            openComposer(detailItem);
          }}
          onTogglePin={() => detailItem && togglePin(detailItem.id)}
          onToggleTopRule={() => detailItem && toggleTopRule(detailItem.id)}
          onSnooze={(d) => detailItem && snooze(detailItem.id, d)}
          onDelete={() => detailItem && deleteItem(detailItem.id)}
        />
      </View>
    </Safe>
  );
}

function HomeScreen({
  spotlight,
  onOpen,
  onCapture,
  onQuickAdd,
  onReflect,
  onSnooze,
  onPin,
  refPulse,
}) {
  const [quickText, setQuickText] = useState("");
  const quickRef = useRef(null);

  const handleQuickAdd = () => {
    const t = quickText.trim();
    if (!t) return;
    onQuickAdd(t);
    setQuickText("");
  };

  return (
    <ScrollView
      contentContainerStyle={{
        paddingBottom: 110,
      }}
      showsVerticalScrollIndicator={false}
    >
      <Header title="Today's reminder" />

      <View style={{ paddingHorizontal: 16 }}>
        {spotlight ? (
          <View style={{ position: "relative" }}>
            <ReflectPulse trigger={refPulse} />
            <Pressable
              onPress={() => onOpen(spotlight.id)}
              style={{
                backgroundColor: T.crd,
                borderRadius: 26,
                borderWidth: 1,
                borderColor: T.cbd,
                padding: 18,
                shadowColor: "#000",
                shadowOpacity: 0.08,
                shadowRadius: 14,
                shadowOffset: { width: 0, height: 10 },
                elevation: 3,
              }}
            >
              <Text style={{ color: T.mut, fontWeight: "900", marginBottom: 10 }}>Daily Spotlight</Text>

              {!!spotlight.title?.trim() ? (
                <Text style={{ color: T.ink, fontSize: 20, fontWeight: "950", lineHeight: 26 }}>
                  {spotlight.title.trim()}
                </Text>
              ) : null}

              {!!spotlight.body?.trim() ? (
                <Text style={{ color: T.sub, fontSize: 15.5, lineHeight: 22, marginTop: 12 }}>
                  {spotlight.body.trim()}
                </Text>
              ) : null}

              <View style={{ flexDirection: "row", alignItems: "center", marginTop: 14, flexWrap: "wrap" }}>
                <PriorityPill p={spotlight.priority} />
                {spotlight.source && spotlight.source !== "Me" ? (
                  <>
                    <View style={{ width: 10 }} />
                    <Text style={{ color: T.mut, fontWeight: "800" }}>From {spotlight.source}</Text>
                  </>
                ) : null}
                {spotlight.pinned ? <Text style={{ marginLeft: 10, fontWeight: "950" }}>★</Text> : null}
              </View>

              {!!spotlight.tags?.length ? (
                <View style={{ flexDirection: "row", flexWrap: "wrap", marginTop: 12 }}>
                  {spotlight.tags.slice(0, 4).map((t) => (
                    <View
                      key={t}
                      style={{
                        paddingHorizontal: 10,
                        paddingVertical: 6,
                        borderRadius: 999,
                        backgroundColor: "#F3F1ED",
                        borderWidth: 1,
                        borderColor: "#E6E2DB",
                        marginRight: 8,
                        marginBottom: 8,
                      }}
                    >
                      <Text style={{ color: T.sub, fontWeight: "800", fontSize: 12 }}>{t}</Text>
                    </View>
                  ))}
                </View>
              ) : null}

              <SoftDivider />

              <View style={{ flexDirection: "row", gap: 10, flexWrap: "wrap" }}>
                <IconButton label="I reflected on this" onPress={onReflect} tone="good" />
                <IconButton label="Snooze" onPress={onSnooze} tone="neutral" />
                <IconButton label={spotlight.pinned ? "Unpin" : "Pin"} onPress={onPin} tone="neutral" />
              </View>
            </Pressable>
          </View>
        ) : (
          <View
            style={{
              backgroundColor: T.crd,
              borderRadius: 26,
              borderWidth: 1,
              borderColor: T.cbd,
              padding: 18,
            }}
          >
            <Text style={{ color: T.ink, fontWeight: "950", fontSize: 18 }}>Your vault is empty.</Text>
            <Text style={{ color: T.sub, marginTop: 8, lineHeight: 20 }}>
              Capture one life rule, insight, or decision — and it’ll start resurfacing daily.
            </Text>
            <View style={{ height: 12 }} />
            <IconButton label="Capture a thought" onPress={onCapture} tone="primary" />
          </View>
        )}

        <View style={{ height: 18 }} />

        <View
          style={{
            backgroundColor: T.crd,
            borderRadius: 22,
            borderWidth: 1,
            borderColor: T.cbd,
            padding: 14,
            flexDirection: "row",
            alignItems: "center",
            gap: 10,
          }}
        >
          <TextInput
            ref={quickRef}
            value={quickText}
            onChangeText={setQuickText}
            placeholder="Type a thought..."
            placeholderTextColor={T.mut}
            onSubmitEditing={handleQuickAdd}
            returnKeyType="done"
            style={{
              flex: 1,
              color: T.ink,
              fontSize: 16,
              fontWeight: "800",
              paddingVertical: 6,
            }}
          />
          {quickText.trim() ? (
            <Pressable
              onPress={handleQuickAdd}
              style={{
                backgroundColor: T.ink,
                borderRadius: 14,
                paddingHorizontal: 14,
                paddingVertical: 8,
              }}
            >
              <Text style={{ color: T.crd, fontWeight: "900", fontSize: 13 }}>Add</Text>
            </Pressable>
          ) : null}
        </View>

        {!quickText.trim() ? (
          <ScrollView
            horizontal
            showsHorizontalScrollIndicator={false}
            style={{ marginTop: 10 }}
          >
            {[
              "Remember to...",
              "Rule: never...",
              "When I feel...",
              "Always ask...",
              "Before I react...",
            ].map((p) => (
              <Pressable
                key={p}
                onPress={() => { setQuickText(p); quickRef.current?.focus(); }}
                style={{
                  backgroundColor: T.crd,
                  borderRadius: 14,
                  borderWidth: 1,
                  borderColor: T.cbd,
                  paddingHorizontal: 12,
                  paddingVertical: 8,
                  marginRight: 8,
                }}
              >
                <Text style={{ color: T.sub, fontWeight: "800", fontSize: 13 }}>{p}</Text>
              </Pressable>
            ))}
          </ScrollView>
        ) : null}

        <View style={{ height: 24 }} />

        <View style={{ alignItems: "center", marginTop: 8, marginBottom: 24 }}>
          <Image
            source={require("./assets/mascot.png")}
            style={{ width: 120, height: 120, opacity: 0.5 }}
            resizeMode="contain"
          />
        </View>
      </View>
    </ScrollView>
  );
}

function LibraryScreen({ items, onOpen, onCapture }) {
  const [q, setQ] = useState("");
  const [filter, setFilter] = useState("all"); // all | pinned | high | wife | recent

  const hasWife = useMemo(() => items.some((x) => (x.source || "").toLowerCase() === "wife"), [items]);

  const filtered = useMemo(() => {
    const qq = q.trim().toLowerCase();

    let xs = [...items];

    if (filter === "pinned") xs = xs.filter((x) => x.pinned);
    if (filter === "high") xs = xs.filter((x) => x.priority === "high");
    if (filter === "wife") xs = xs.filter((x) => (x.source || "").toLowerCase() === "wife");
    if (filter === "top3") xs = xs.filter((x) => x.topRule);
    if (filter === "recent") xs = xs.sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));

    if (qq) {
      xs = xs.filter((x) => {
        const hay = [
          x.title || "",
          x.body || "",
          (x.source || ""),
          ...(x.tags || []),
        ]
          .join(" ")
          .toLowerCase();
        return hay.includes(qq);
      });
    }

    // Default sort: pinned first, then priority, then updatedAt
    xs = xs.sort((a, b) => {
      const ap = a.pinned ? 1 : 0;
      const bp = b.pinned ? 1 : 0;
      if (bp !== ap) return bp - ap;
      const pr = priorityScore(b.priority) - priorityScore(a.priority);
      if (pr !== 0) return pr;
      return (b.updatedAt || 0) - (a.updatedAt || 0);
    });

    return xs;
  }, [items, q, filter]);

  return (
    <View style={{ flex: 1 }}>
      <Header
        title="Library"
        subtitle="Your personal philosophy vault."
        right={
          <View style={{ gap: 10 }}>
            <View
              style={{
                backgroundColor: T.crd,
                borderRadius: 18,
                borderWidth: 1,
                borderColor: T.cbd,
                paddingHorizontal: 12,
                paddingVertical: 10,
              }}
            >
              <TextInput
                value={q}
                onChangeText={setQ}
                placeholder="Search…"
                placeholderTextColor={T.mut}
                style={{ color: T.ink, fontWeight: "800" }}
              />
            </View>

            <ScrollView horizontal showsHorizontalScrollIndicator={false}>
              <Chip label="All" active={filter === "all"} onPress={() => setFilter("all")} />
              <Chip label="Pinned" active={filter === "pinned"} onPress={() => setFilter("pinned")} />
              <Chip label="High" active={filter === "high"} onPress={() => setFilter("high")} />
              {hasWife ? <Chip label="From Wife" active={filter === "wife"} onPress={() => setFilter("wife")} /> : null}
              <Chip label="Top 3 ✦" active={filter === "top3"} onPress={() => setFilter("top3")} />
              <Chip label="Recent" active={filter === "recent"} onPress={() => setFilter("recent")} />
            </ScrollView>
          </View>
        }
      />

      <View style={{ paddingHorizontal: 16, flex: 1, paddingBottom: 110 }}>
        {filtered.length ? (
          <FlatList
            data={filtered}
            keyExtractor={(it) => it.id}
            renderItem={({ item }) => <ReminderCard item={item} onOpen={() => onOpen(item.id)} />}
            showsVerticalScrollIndicator={false}
          />
        ) : (
          <View
            style={{
              backgroundColor: T.crd,
              borderRadius: 26,
              borderWidth: 1,
              borderColor: T.cbd,
              padding: 18,
              marginTop: 10,
            }}
          >
            <Text style={{ color: T.ink, fontWeight: "950", fontSize: 18 }}>Nothing here yet.</Text>
            <Text style={{ color: T.sub, marginTop: 8, lineHeight: 20 }}>
              Capture a rule, lesson, or insight — keep it one sentence.
            </Text>
            <View style={{ height: 12 }} />
            <IconButton label="Capture a thought" onPress={onCapture} tone="primary" />
          </View>
        )}
      </View>
    </View>
  );
}

function HabitsScreen({ items, onOpen, onAddHabit }) {
  return (
    <View style={{ flex: 1 }}>
      <Header
        title="Habits"
        subtitle="Only prompts. No streaks. No shame."
        right={<IconButton label="Add habit reminder" onPress={onAddHabit} tone="primary" />}
      />

      <View style={{ paddingHorizontal: 16, flex: 1, paddingBottom: 110 }}>
        {items.length ? (
          <FlatList
            data={[...items].sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0))}
            keyExtractor={(it) => it.id}
            renderItem={({ item }) => (
              <Pressable
                onPress={() => onOpen(item.id)}
                style={{
                  backgroundColor: T.crd,
                  borderRadius: 22,
                  borderWidth: 1,
                  borderColor: T.cbd,
                  padding: 16,
                  marginBottom: 12,
                }}
              >
                <Text style={{ color: T.ink, fontWeight: "950", fontSize: 16 }}>{item.title}</Text>
                <Text style={{ color: T.mut, fontWeight: "800", marginTop: 8 }}>
                  Shows on the home screen when selected for today.
                </Text>
              </Pressable>
            )}
            showsVerticalScrollIndicator={false}
          />
        ) : (
          <View
            style={{
              backgroundColor: T.crd,
              borderRadius: 26,
              borderWidth: 1,
              borderColor: T.cbd,
              padding: 18,
              marginTop: 10,
            }}
          >
            <Text style={{ color: T.ink, fontWeight: "950", fontSize: 18 }}>No habit prompts yet.</Text>
            <Text style={{ color: T.sub, marginTop: 8, lineHeight: 20 }}>
              Add 1–3 habits you want gently surfaced — that’s it.
            </Text>
            <View style={{ height: 12 }} />
            <IconButton label="Add habit reminder" onPress={onAddHabit} tone="primary" />
          </View>
        )}
      </View>
    </View>
  );
}
