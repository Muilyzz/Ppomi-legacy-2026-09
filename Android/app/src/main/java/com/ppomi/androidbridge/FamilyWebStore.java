package com.ppomi.androidbridge;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.UUID;

/** Process-pinned release store. An unconfirmed launch rolls back without replaying application actions. */
final class FamilyWebStore {
    private final FamilyWebPackage.Config config;
    private final Path root;
    private final Path stateFile;
    private final Path lockFile;
    private String selected;
    private boolean started;
    private boolean readinessFailed;

    static final class Selection {
        final File root;
        final String release;
        final boolean trial;
        Selection(File root, String release, boolean trial) { this.root = root; this.release = release; this.trial = trial; }
    }
    FamilyWebStore(File storage, FamilyWebPackage.Config config) throws Exception {
        this.config = config;
        root = storage.toPath().resolve(config.namespace);
        Files.createDirectories(root);
        FamilyWebPackage.require(!Files.isSymbolicLink(root));
        syncDirectory(root.getParent());
        syncDirectory(root.getParent().getParent());
        stateFile = root.resolve("state.properties");
        lockFile = root.resolve("store.lock");
    }

    synchronized Selection beginLaunch() throws Exception {
        FamilyWebPackage.require(!started);
        started = true;
        try (FileChannel channel = FileChannel.open(lockFile, StandardOpenOption.CREATE, StandardOpenOption.WRITE);
             FileLock ignored = channel.lock()) {
            State state = readState();
            boolean rolledBack = state.trial;
            if (rolledBack) { state.current = state.previous; state.previous = ""; state.trial = false; }
            FamilyWebPackage current = valid(state.current);
            if (current == null) {
                state.current = state.previous; state.previous = "";
                current = valid(state.current);
                if (current == null) state.current = "";
            }
            if (!rolledBack && !state.pending.isEmpty()) {
                FamilyWebPackage candidate = valid(state.pending);
                if (candidate != null) {
                    state.previous = state.current;
                    state.current = state.pending;
                    state.trial = true;
                    current = candidate;
                }
                state.pending = "";
            }
            writeState(state);
            selected = state.current;
            cleanup(state);
            return current == null ? new Selection(null, "bundled", false)
                : new Selection(root.resolve(selected).toFile(), current.release, state.trial);
        }
    }

    /** Downloads may stage after startup, but this selection never changes within the process. */
    synchronized boolean stage(byte[] bytes) throws Exception {
        FamilyWebPackage update = FamilyWebPackage.verify(bytes, config);
        try (FileChannel channel = FileChannel.open(lockFile, StandardOpenOption.CREATE, StandardOpenOption.WRITE);
             FileLock ignored = channel.lock()) {
            State state = readState();
            if (update.sequence <= state.highest) return false;
            Path target = root.resolve(update.directory);
            Path temporary = root.resolve("stage-" + UUID.randomUUID());
            Files.createDirectory(temporary);
            try {
                for (Map.Entry<String, byte[]> file : update.files.entrySet()) {
                    Path destination = temporary.resolve(file.getKey());
                    Files.createDirectories(destination.getParent());
                    durableWrite(destination, file.getValue());
                }
                durableWrite(temporary.resolve(".package.json"), update.envelope);
                // A leftover target can only be an interrupted, never-accepted stage at this sequence.
                if (Files.exists(target, LinkOption.NOFOLLOW_LINKS)) remove(target);
                Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE);
                syncDirectory(root);
                state.pending = update.directory;
                state.highest = update.sequence;
                writeState(state);
            } finally { if (Files.exists(temporary, LinkOption.NOFOLLOW_LINKS)) remove(temporary); }
            cleanup(state);
            return true;
        }
    }

    synchronized void ready() throws Exception {
        FamilyWebPackage.require(started && !readinessFailed);
        if (selected == null || selected.isEmpty()) return;
        try (FileChannel channel = FileChannel.open(lockFile, StandardOpenOption.CREATE, StandardOpenOption.WRITE);
             FileLock ignored = channel.lock()) {
            State state = readState();
            FamilyWebPackage.require(state.current.equals(selected));
            state.trial = false;
            writeState(state);
        }
    }
    synchronized void failedStartup() { readinessFailed = true; }

    private FamilyWebPackage valid(String name) {
        if (name.isEmpty()) return null;
        try {
            Path directory = root.resolve(name);
            FamilyWebPackage.require(Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS));
            Path manifest = directory.resolve(".package.json");
            FamilyWebPackage.require(Files.isRegularFile(manifest, LinkOption.NOFOLLOW_LINKS));
            FamilyWebPackage update;
            try (InputStream input = Files.newInputStream(manifest)) { update = FamilyWebPackage.verify(readBounded(input, FamilyWebPackage.MAX_ENVELOPE), config); }
            FamilyWebPackage.require(update.directory.equals(name));
            for (Map.Entry<String, byte[]> file : update.files.entrySet()) {
                Path path = directory.resolve(file.getKey());
                Path parent = path.getParent();
                while (!parent.equals(directory)) { FamilyWebPackage.require(!Files.isSymbolicLink(parent)); parent = parent.getParent(); }
                FamilyWebPackage.require(Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS));
                try (InputStream input = Files.newInputStream(path)) {
                    FamilyWebPackage.require(Arrays.equals(readBounded(input, FamilyWebPackage.MAX_FILE), file.getValue()));
                }
            }
            // No unsigned files may be served from a signed directory.
            Set<String> expected = new HashSet<>(update.files.keySet()); expected.add(".package.json");
            try (java.util.stream.Stream<Path> paths = Files.walk(directory)) {
                paths.filter(path -> !Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS)).forEach(path -> {
                    FamilyWebPackage.require(!Files.isSymbolicLink(path));
                    FamilyWebPackage.require(expected.remove(directory.relativize(path).toString()));
                });
            }
            FamilyWebPackage.require(expected.isEmpty());
            return update;
        } catch (Exception ignored) { return null; }
    }

    private static final class State {
        int highest;
        String current = "", previous = "", pending = "";
        boolean trial;
    }
    private State readState() throws Exception {
        State state = new State();
        if (!Files.exists(stateFile, LinkOption.NOFOLLOW_LINKS)) return state;
        FamilyWebPackage.require(Files.isRegularFile(stateFile, LinkOption.NOFOLLOW_LINKS));
        Properties value = new Properties();
        try (InputStream input = Files.newInputStream(stateFile)) {
            value.load(new java.io.ByteArrayInputStream(readBounded(input, 4096)));
        }
        FamilyWebPackage.require(value.stringPropertyNames().equals(new HashSet<>(Arrays.asList("format", "highest", "current", "previous", "pending", "trial"))));
        FamilyWebPackage.require(value.getProperty("format").equals("1"));
        state.highest = Integer.parseInt(value.getProperty("highest"));
        FamilyWebPackage.require(state.highest >= 0);
        state.current = storedName(value.getProperty("current"));
        state.previous = storedName(value.getProperty("previous"));
        state.pending = storedName(value.getProperty("pending"));
        String trial = value.getProperty("trial");
        FamilyWebPackage.require(trial.equals("true") || trial.equals("false")); state.trial = trial.equals("true");
        for (String name : Arrays.asList(state.current, state.previous, state.pending))
            if (!name.isEmpty()) FamilyWebPackage.require(Integer.parseInt(name.substring(0, name.indexOf('-'))) <= state.highest);
        FamilyWebPackage.require(!state.trial || !state.current.isEmpty());
        return state;
    }
    private String storedName(String name) {
        FamilyWebPackage.require(name != null && (name.isEmpty() || name.matches("[1-9][0-9]{0,9}-[a-f0-9]{64}"))); return name;
    }
    private void writeState(State state) throws Exception {
        Properties value = new Properties();
        value.setProperty("format", "1"); value.setProperty("highest", Integer.toString(state.highest));
        value.setProperty("current", state.current); value.setProperty("previous", state.previous);
        value.setProperty("pending", state.pending); value.setProperty("trial", Boolean.toString(state.trial));
        ByteArrayOutputStream output = new ByteArrayOutputStream(); value.store(output, null);
        Path temporary = root.resolve("state-" + UUID.randomUUID());
        try {
            durableWrite(temporary, output.toByteArray());
            Files.move(temporary, stateFile, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            syncDirectory(root);
        }
        finally { Files.deleteIfExists(temporary); }
    }
    private static void durableWrite(Path file, byte[] bytes) throws Exception {
        try (OutputStream output = Files.newOutputStream(file, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) { output.write(bytes); }
        try (FileChannel channel = FileChannel.open(file, StandardOpenOption.WRITE)) { channel.force(true); }
    }
    private static void syncDirectory(Path directory) throws Exception {
        try (FileChannel channel = FileChannel.open(directory, StandardOpenOption.READ)) { channel.force(true); }
    }
    private void cleanup(State state) throws Exception {
        Set<String> keep = new HashSet<>(Arrays.asList(state.current, state.previous, state.pending, "state.properties", "store.lock"));
        if (selected != null) keep.add(selected);
        try (java.nio.file.DirectoryStream<Path> paths = Files.newDirectoryStream(root)) {
            for (Path path : paths) if (!keep.contains(path.getFileName().toString())) remove(path);
        }
    }
    private static void remove(Path path) throws Exception {
        if (Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS)) {
            try (java.nio.file.DirectoryStream<Path> children = Files.newDirectoryStream(path)) { for (Path child : children) remove(child); }
        }
        Files.delete(path);
    }
    static byte[] readBounded(InputStream input, int maximum) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream(); byte[] buffer = new byte[16384]; int count;
        while ((count = input.read(buffer)) != -1) {
            FamilyWebPackage.require(output.size() + (long) count <= maximum); output.write(buffer, 0, count);
        }
        return output.toByteArray();
    }
}
