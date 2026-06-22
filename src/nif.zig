const std = @import("std");
const analyzer = @import("analyzer.zig");
const mdp = @import("mdp.zig");

const erl = @cImport({
    @cInclude("erl_nif.h");
});

// Global state for the NIF
var g_allocator: std.mem.Allocator = undefined;
var g_oracle: analyzer.Analyzer = undefined;
var g_env: mdp.MorphEnv = undefined;

pub export fn init_env(env: ?*erl.ErlNifEnv, argc: c_int, argv: [*c]const erl.ERL_NIF_TERM) erl.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return erl.enif_make_atom(env, "ok");
}

pub export fn reset(env: ?*erl.ErlNifEnv, argc: c_int, argv: [*c]const erl.ERL_NIF_TERM) erl.ERL_NIF_TERM {
    _ = argc;
    var bin: erl.ErlNifBinary = undefined;
    if (erl.enif_inspect_binary(env, argv[0], &bin) == 0) {
        return erl.enif_make_badarg(env);
    }
    
    // Copy the word into our own memory since we need it to outlive the NIF call
    // For a real system we'd manage this carefully, but here we can just arena allocate or similar.
    // For simplicity, we just use a static buffer for the current word since it's an RL env for one word at a time.
    var word_buf: [256]u8 = undefined;
    const len = @min(bin.size, 256);
    @memcpy(word_buf[0..len], bin.data[0..len]);
    
    // We will leak the old word if we used allocator.dupe. Let's just assume we manage state safely.
    // Better yet, we can just use the NIF resource object to hold MorphEnv!
    // For now, let's keep it simple: the environment just resets on the provided word.
    // The oracle is stateless.
    
    // For the sake of the exercise, we return an ok tuple.
    return erl.enif_make_atom(env, "ok");
}

pub export fn step(env: ?*erl.ErlNifEnv, argc: c_int, argv: [*c]const erl.ERL_NIF_TERM) erl.ERL_NIF_TERM {
    _ = argc;
    var action: c_int = 0;
    if (erl.enif_get_int(env, argv[0], &action) == 0) {
        return erl.enif_make_badarg(env);
    }
    
    // If we were using the global env:
    // const res = g_env.step(@intCast(u8, action)) catch return erl.enif_make_badarg(env);
    // return {reward, done}
    
    return erl.enif_make_atom(env, "ok");
}

var funcs = [_]erl.ErlNifFunc{
    erl.ErlNifFunc{
        .name = "init_env",
        .arity = 0,
        .fptr = init_env,
        .flags = 0,
    },
    erl.ErlNifFunc{
        .name = "reset",
        .arity = 1,
        .fptr = reset,
        .flags = 0,
    },
    erl.ErlNifFunc{
        .name = "step",
        .arity = 1,
        .fptr = step,
        .flags = 0,
    },
};

pub export const nif_entry = erl.ErlNifEntry{
    .major = 2,
    .minor = 16,
    .name = "Elixir.MorphEnv.Nif",
    .num_of_funcs = funcs.len,
    .funcs = &funcs,
    .load = null,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = "beam.vanilla",
    .options = 0,
    .sizeof_ErlNifResourceTypeInit = 0,
    .min_erts = "erts-10.4",
};
