/*
    Credits
        Sebastien S. (SystemFailu.re) : Creating main script, reversing engine.
        ellomenop : Doing original splits, helping test & misc. bug fixes.
        Museus: Routed, midbiome, enter boss arena, overhaul of logic and sig scanning
        cgull: House splits + splits on boss kill, revamp for Hades II.
        iDeathHD: solved the 23 length string crisis of 2024
        Sam C. (froggy) : Olympic & Warsong updates
*/

state("Hades2")
{
    /*
        There's nothing here because I don't want to use static instance addresses..
        Please refer to `init` to see the signature scanning.
    */
}

startup
{
    vars.Log = (Action<object>)((output) => print("[Hades 2 ASL] " + output));
    vars.InitComplete = false;

    settings.Add("multiWep", false, "Multi Weapon Run");
    settings.Add("resetOnSeedRoll", false, "Reset Splits on Seed Reroll");
    settings.Add("houseSplits", false, "Use Crossroads Splits", "multiWep");
    settings.Add("enterBossArena", true, "Split when entering boss arena");
    settings.Add("splitOnBossKill", true, "Split on Boss Kills");
    settings.Add("midbiome", false, "Split when exiting inter-biome");
    settings.Add("routed", false, "Routed (per chamber)");
    
}

init
{
    vars.InitComplete = false;
    vars.CancelSource = new CancellationTokenSource();
    vars.quick_restart_mod = false;

    System.Threading.Tasks.Task.Run(async () =>
    {
        task_start: try {
            while (true)
            {
                // DX = EngineWin64s.dll, VK = EngineWin64sv.dll
                // Have to use game.ModulesWow64Safe() because modules variable doesn't update inside Tasks
                var engine = game.ModulesWow64Safe().FirstOrDefault(x => x.ModuleName.StartsWith("Hades2"));
                if (engine == null){
                    vars.Log("Engine not loaded yet, trying again.");
                    await System.Threading.Tasks.Task.Delay(1000, vars.CancelSource.Token);
                    continue;
                }
                vars.Log("Found engine!");

                var signature_scanner = new SignatureScanner(game, engine.BaseAddress, engine.ModuleMemorySize);

                /* Signatures */
                // sgg:App::Instance : MOV qword ptr [sgg::App::INSTANCE]
                var app_signature_target = new SigScanTarget(3, "48 89 05 ?? ?? ?? ?? 75 ?? 4C 8D 0D ?? ?? ?? ?? 41 B8 ?? ?? ?? ?? 48 8D 15");
                // sgg::App::CheckBugReport : MOV RAX,qword ptr [sgg::world]
                var world_signature_target = new SigScanTarget(3, "48 8B 05 ?? ?? ?? ?? 48 8B CD");
                // sgg::MiscSettingsScreen::OnToggleRumble : end of func "MOV param_1=>`public:_static_class_sgg:PlayerManager"
                var player_manager_signature_target = new SigScanTarget(3, "48 8B 15 ?? ?? ?? ?? 48 FF C3 E9 ?? ?? ?? ?? 0F 29 74 24");

                var signature_targets = new [] {
                    app_signature_target,
                    world_signature_target,
                    player_manager_signature_target,
                };

                foreach (var target in signature_targets) {
                    target.OnFound = (process, _, pointer) => process.ReadPointer(pointer + 0x4 + process.ReadValue<int>(pointer));
                }

                IntPtr app = signature_scanner.Scan(app_signature_target);
                vars.world = signature_scanner.Scan(world_signature_target);
                IntPtr player_manager = signature_scanner.Scan(player_manager_signature_target);

                vars.screen_manager = game.ReadPointer(app + 0x698); // App.pScreenManager
                vars.current_player = game.ReadPointer(game.ReadPointer(player_manager + 0x18)); // PlayerManager.mPlayers

                vars.InitComplete = true;
                break;
            }

            vars.CancelSource.Cancel();
        }
        catch (ArgumentException) {
            // Hopefully will be fixed by https://github.com/LiveSplit/LiveSplit/pull/2203
            goto task_start;
        }
        catch (Exception ex) {
            vars.Log("Task abort.\n" + ex);
        }
    });

    current.run_time = "0:0.1";
    current.map = "";

    current.total_seconds = 0.5f;
    old.total_seconds = 0.5f;

    vars.time_split = current.run_time.Split(':', '.');
    vars.has_beat_final_boss = false;
    vars.boss_killed = false;

    vars.still_in_arena = false;
    vars.seed_rerolled = false;

    vars.game_ui = IntPtr.Zero;
}

update
{
    if (!(vars.InitComplete))
        return false;

    IntPtr hash_table = game.ReadPointer((IntPtr) vars.current_player + 0x40); // Player.mInputBlocks
    for(int i = 0; i < 5; i++)
    {
        IntPtr block = game.ReadPointer(hash_table + 0x8 * i);
        if(block == IntPtr.Zero)
            continue;

        string block_name = "";

        bool isChonosKill = (game.ReadValue<byte>(block + 23) & 0x0F) == 0x0F;
        bool isSSOString = (game.ReadValue<byte>(block + 23) & 0x80) == 0;

        if (isChonosKill)
        {
            block = game.ReadPointer(block + 0x18);
            block_name = game.ReadString(block, 128);

            if (block_name == null)
                continue;

            // vars.Log("(update) chronos block_name: " + block_name);
        }
        else if (isSSOString)
        {
            block_name = game.ReadString(block, 24);

            if (block_name == null)
                continue;

            //vars.Log("(update) sso block_name: " + block_name);
        }
        else
        {
            block = game.ReadPointer(block);
            block_name = game.ReadString(block, 128);
            
            if (block_name == null)
                continue;

            //vars.Log("(update) block_name: " + block_name);
        }

        vars.Log("(update) Encountered block: " + block_name);

        vars.seed_rerolled = block_name == "SpecialInteractChangeNextRunRNG";

        var boss_killed_block = block_name == "GenericBossKillPresentation" || block_name == "ErisKillPresentation" || block_name == "HecateKillPresentation" || block_name == "PrometheusKillPresentation";
        var ignored_boss_map = (
            current.map == "G_MiniBoss02" || current.map == "O_MiniBoss01" || // Uh-Oh! || Charybdis
            current.map == "P_MiniBoss01" || current.map == "Q_MiniBoss02" || // Talos || _ of Typhon
            current.map == "Q_MiniBoss03" || current.map == "Q_MiniBoss04" || current.map == "Q_MiniBoss05" || // _ of Typhon
            current.map == "N_MiniBoss02" || current.map == "C_Boss01" || // erymanthian boar  || Zagreus
            current.map == "I_Boss01" || current.map == "Q_Boss01" || current.map== "Q_Boss02" // Chronos - handled by has_beat_final_boss Typhon - handled by has_beat_final_boss
        );
        if (!vars.boss_killed && boss_killed_block && !ignored_boss_map)
        {
            vars.Log("(update) Detected boss kill");
            vars.boss_killed = true;
        }

        if (!vars.has_beat_final_boss &&
            (block_name == "ChronosKillPresentation" || block_name == "TyphonSpecialKillPresentation" || (block_name == "TyphonHeadKillPresentation" && current.map == "Q_Boss01")))
        {
            vars.Log("(update) Detected Chronos/Typhon kill");
            vars.has_beat_final_boss = true;
        }
    }

    // Get the array of screen IntPtrs and iterate to find InGameUI screen
    if (vars.screen_manager != IntPtr.Zero)
    {
        IntPtr screen_vector_begin = game.ReadPointer((IntPtr)vars.screen_manager + 0x48); // sgg::ScreenManager.mScreens
        IntPtr screen_vector_end = game.ReadPointer((IntPtr)vars.screen_manager + 0x50); // 0x48 + 0x8

        var num_screens = (screen_vector_end.ToInt64() - screen_vector_begin.ToInt64()) / 8;

        // Maybe only loop once to find game_ui, not sure if pointer is destructed anytime.
        for (int i = 0; i < num_screens; i++)
        {
            IntPtr current_screen = game.ReadPointer(screen_vector_begin + 0x8 * i);
            if (current_screen == IntPtr.Zero)
                continue;

            IntPtr screen_vtable = game.ReadPointer(current_screen); // Deref to get vtable
            IntPtr get_type_method = game.ReadPointer(screen_vtable + 0x50); // sgg::GameScreen_vtbl GetType
            int screen_type = game.ReadValue<int>(get_type_method + 0x1); // sgg::ScreenType

            // InGameUI is screen type 7
            if ((screen_type & 0x7) == 7) {
                vars.game_ui = current_screen;
                break;
            }
        }
    }

    /* Get our current run time */
    if (vars.game_ui != IntPtr.Zero) // sgg::InGameUI
    {
        IntPtr runtime_component = game.ReadPointer((IntPtr)vars.game_ui + 0x300); // InGameUI.mElapsedRunTimeText
        if (runtime_component != IntPtr.Zero)
        {
            /* This might break if the run goes over 99 minutes T_T */
            current.run_time = game.ReadString(game.ReadPointer(runtime_component + 0x5B8), 0x8); // GUIComponentTextBox.mStringBuilder
            if (current.run_time == "PauseScr")
                current.run_time = "0:0.10";
        }
    }

    /* Get our current map name */
    if(vars.world != IntPtr.Zero)
    {
        IntPtr map_data = game.ReadPointer((IntPtr)vars.world + 0xA0); // World.nMap 0x80 + Map.mData 0x20 = 0xA0
        if(map_data != IntPtr.Zero)
            current.map = game.ReadString(map_data, 0x10);
            if (current.map != old.map)
                vars.Log("(update) Map change: " + old.map + " -> " + current.map);

            if (vars.still_in_arena && current.map != old.map)
            {
                vars.still_in_arena = false;
                vars.boss_killed = false;
                vars.has_beat_final_boss = false;
            }
    }

    splitTime: try {
    vars.time_split = current.run_time.Split(':', '.');
    /* Convert the string time to singles */
    current.total_seconds =
        int.Parse(vars.time_split[0]) * 60 +
        int.Parse(vars.time_split[1]) +
        float.Parse(vars.time_split[2]) / 100;
    } catch (IndexOutOfRangeException) {
        current.total_seconds = old.total_seconds;
    }
}

onStart
{
    vars.boss_killed = false;
    vars.has_beat_final_boss = false;
    vars.still_in_arena = false;
}

start
{
    // Start the timer if in the first room and the old timer is greater than the new (memory address holds the value from the previous run)
    var is_opening_chamber = (
        current.map == "F_Opening01" || current.map == "F_Opening02" || // Erebus
        current.map == "F_Opening03" || current.map=="N_Opening01" // Erebus || Ephyrya
    );
    if (old.total_seconds > current.total_seconds && is_opening_chamber)
    {
        return true;
    }
}

onSplit
{
    vars.boss_killed = false;
    vars.has_beat_final_boss = false;
}

split
{
    // Split on Chronos/Typhon Kill
    if (!vars.still_in_arena && vars.has_beat_final_boss)
    {
        // Disable boss kill detection until we leave the boss arena
        vars.still_in_arena = true;
        vars.Log(current.run_time + " (split) Splitting for Chronos/Typhon kill");
        return true;
    }

    // Split on Boss Kill
    if (settings["splitOnBossKill"] && !vars.still_in_arena && vars.boss_killed)
    {
        // Disable boss kill detection until we leave the boss arena
        vars.still_in_arena = true;

        vars.Log(current.run_time + " (splitOnBossKill) Splitting for boss kill");
        return true;
    }

    // Split on run start if Crossroads Splits are enabled
    if (settings["multiWep"] && settings["houseSplits"])
    {
        if (current.map == "Hub_PreRun" && (old.total_seconds > current.total_seconds))
        {
            vars.Log(current.run_time + " (multiWep && houseSplits) Splitting for house split");
            return true;
        }
    }

    var entered_new_room = current.map != old.map;

    // Split every chamber if Routed is enabled
    if (settings["routed"] && entered_new_room)
    {
        vars.Log(current.run_time +" (routed) Splitting for chamber transition: " + old.map + " -> " + current.map);
        return true;
    }

    // Split on room transition
    if (entered_new_room)
    {
        // leaving boss room
        // TODO check in Chronos/Typhon room ??
        if (current.map == "F_PostBoss01" || current.map == "G_PostBoss01" || // Erebus/Hecate || Oceanus/Sirens
            current.map == "H_PostBoss01" || current.map == "N_PostBoss01" || // Fields/Cerberus || Ephyra/Polyphemus
            current.map == "O_PostBoss01" || current.map == "P_PostBoss01") // Rift/Eris || Olympus/Prometheus
        
        {
            if (!settings["splitOnBossKill"])
            {
                vars.Log(current.run_time + " (!splitOnBossKill) Splitting for exiting boss arena: " + old.map);
                return true;
            }
        }

        // exiting interbiome chamber
        if (old.map == "F_PostBoss01" || old.map == "G_PostBoss01" || // Erebus/Hecate || Oceanus/Sirens
            old.map == "H_PostBoss01" || old.map == "N_PostBoss01" || // Fields/Cerberus || Ephyra/Polyphemus
            old.map == "O_PostBoss01" || old.map == "P_PostBoss01") // Rift/Eris || // Olympus/Prometheus
        {
            if (settings["midbiome"])
            {
                vars.Log(current.run_time + " (midbiome) Splitting for leaving interbiome: " + old.map);
                return true;
            }
        }

        // entering chronos/typhon, always splits here
        if (current.map == "I_Boss01" || current.map == "Q_Boss01" || current.map == "Q_Boss02" )
        {
            vars.Log(current.run_time + "Splitting for entering final boss arena: " + current.map);
            return true;
        }

        // entering boss chamber
        if (current.map == "F_Boss01" || current.map == "F_Boss02" || current.map == "G_Boss01" || current.map == "G_Boss02" || // Erebus/Hecate || Oceanus/Sirens
            current.map == "H_Boss01" || current.map == "H_Boss02" ||  // Fields/Cerberus
            current.map == "N_Boss01" || current.map == "N_Boss02" ||current.map == "O_Boss01" || current.map == "O_Boss02" || // Ephyra/Polyphemus || Rift/Eris
            current.map == "P_Boss01") // Olympus/Prometheus 
        {
            if (settings["enterBossArena"])
            {
                vars.Log(current.run_time + " (enterBossArena) Splitting for entering boss arena: " + current.map);
                return true;

            }

        }
    }
}

onReset
{
    vars.time_split = "0:0.1".Split(':', '.');
    current.total_seconds = 0.5f;
    old.total_seconds = 0.5f;

    vars.boss_killed = false;
    vars.has_beat_final_boss = false;
}

reset
{
    // Reset and clear state if Mel is currently in the courtyard.  Don't reset in multiweapon runs
    if(!settings["multiWep"] && current.map == "Hub_PreRun")
    {
        vars.Log("(reset) Resetting for courtyard");
        return true;
    }
    if(settings["resetOnSeedRoll"] && vars.seed_rerolled)
    {
        vars.seed_rerolled = false;
        return true;
    }
}

gameTime
{
    return TimeSpan.FromSeconds(current.total_seconds);
}

isLoading
{
    /*
    Because we just override the gameTime constantly with in-game timer, we
    don't need a fancy load sensor. For a Loadless RTA setting, this will need
    to be actually evaluated, but for now just pretend we are always loading.
    */
    return true;
}

exit
{
    vars.CancelSource.Cancel();
    vars.InitComplete = false;
}

shutdown
{
    vars.CancelSource.Cancel();
}



