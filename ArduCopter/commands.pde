// -*- tab-width: 4; Mode: C++; c-basic-offset: 4; indent-tabs-mode: nil -*-

static void init_commands()
{
    g.command_index         = NO_COMMAND;
    command_nav_index       = NO_COMMAND;
    command_cond_index      = NO_COMMAND;
    prev_nav_index          = NO_COMMAND;
    command_cond_queue.id   = NO_COMMAND;
    command_nav_queue.id    = NO_COMMAND;
}

// Getters
// -------
static struct Location get_cmd_with_index(int i)
{
    struct Location temp;

    // Find out proper location in memory by using the start_byte position + the index
    // --------------------------------------------------------------------------------
    if (i >= g.command_total) {
        // we do not have a valid command to load
        // return a WP with a "Blank" id
        temp.id = CMD_BLANK;

        // no reason to carry on
        return temp;

    }else{
        // we can load a command, we don't process it yet
        // read WP position
        uint16_t mem = (WP_START_BYTE) + (i * WP_SIZE);

        temp.id = hal.storage->read_byte(mem);

        mem++;
        temp.options = hal.storage->read_byte(mem);

        mem++;
        temp.p1 = hal.storage->read_byte(mem);

        mem++;
        temp.alt = hal.storage->read_dword(mem);           // alt is stored in CM! Alt is stored relative!

        mem += 4;
        temp.lat = hal.storage->read_dword(mem);         // lat is stored in decimal * 10,000,000

        mem += 4;
        temp.lng = hal.storage->read_dword(mem);         // lon is stored in decimal * 10,000,000
    }

    // Add on home altitude if we are a nav command (or other command with altitude) and stored alt is relative
    //if((temp.id < MAV_CMD_NAV_LAST || temp.id == MAV_CMD_CONDITION_CHANGE_ALT) && temp.options & MASK_OPTIONS_RELATIVE_ALT){
    //temp.alt += home.alt;
    //}

    if(temp.options & WP_OPTION_RELATIVE) {
        // If were relative, just offset from home
        temp.lat        +=      home.lat;
        temp.lng        +=      home.lng;
    }

    return temp;
}

// Setters
// -------
static void set_cmd_with_index(struct Location temp, int i)
{

    i = constrain(i, 0, g.command_total.get());
    //cliSerial->printf("set_command: %d with id: %d\n", i, temp.id);

    // store home as 0 altitude!!!
    // Home is always a MAV_CMD_NAV_WAYPOINT (16)
    if (i == 0) {
        temp.alt = 0;
        temp.id = MAV_CMD_NAV_WAYPOINT;
    }

    uint16_t mem = WP_START_BYTE + (i * WP_SIZE);

    hal.storage->write_byte(mem, temp.id);

    mem++;
    hal.storage->write_byte(mem, temp.options);

    mem++;
    hal.storage->write_byte(mem, temp.p1);

    mem++;
    hal.storage->write_dword(mem, temp.alt);     // Alt is stored in CM!

    mem += 4;
    hal.storage->write_dword(mem, temp.lat);     // Lat is stored in decimal degrees * 10^7

    mem += 4;
    hal.storage->write_dword(mem, temp.lng);     // Long is stored in decimal degrees * 10^7

    // Make sure our WP_total
    if(g.command_total < (i+1))
        g.command_total.set_and_save(i+1);
}

static int32_t get_RTL_alt()
{
    if(g.rtl_altitude <= 0) {
		return min(current_loc.alt, RTL_ALT_MAX);
    }else if (g.rtl_altitude < current_loc.alt) {
		return min(current_loc.alt, RTL_ALT_MAX);
    }else{
        return g.rtl_altitude;
    }
}


//********************************************************************************
// This function sets the waypoint and modes for Return to Launch
// It's not currently used
//********************************************************************************

/*
 *  This function sets the next waypoint command
 *  It precalculates all the necessary stuff.
 */

static void set_next_WP(struct Location *wp)
{
    // copy the current WP into the OldWP slot
    // ---------------------------------------
    if (next_WP.lat == 0 || command_nav_index <= 1) {
        prev_WP = current_loc;
    }else{
        if (get_distance_cm(&current_loc, &next_WP) < 500)
            prev_WP = next_WP;
        else
            prev_WP = current_loc;
    }

    // Load the next_WP slot
    // ---------------------
    next_WP.options = wp->options;
    next_WP.lat = wp->lat;
    next_WP.lng = wp->lng;

    // Set new target altitude so we can track it for climb_rate
    // To-Do: remove the restriction on negative altitude targets (after testing)
    set_new_altitude(max(wp->alt,100));

    // recalculate waypoint distance and bearing
    wp_distance             = get_distance_cm(&current_loc, &next_WP);
    wp_bearing              = get_bearing_cd(&prev_WP, &next_WP);
    original_wp_bearing     = wp_bearing;       // to check if we have missed the WP
}

// set_next_WP_latlon - update just lat and lon targets for nav controllers
static void set_next_WP_latlon(uint32_t lat, uint32_t lon)
{
    // save current location as previous location
    prev_WP = current_loc;

    // Load the next_WP slot
    next_WP.lat = lat;
    next_WP.lng = lon;

    // recalculate waypoint distance and bearing
    // To-Do: these functions are too expensive to be called every time we update the next_WP
    wp_distance             = get_distance_cm(&current_loc, &next_WP);
    wp_bearing              = get_bearing_cd(&prev_WP, &next_WP);
    original_wp_bearing     = wp_bearing;       // to check if we have missed the WP
}

// run this at setup on the ground
// -------------------------------
static void init_home()
{
    set_home_is_set(true);
    home.id         = MAV_CMD_NAV_WAYPOINT;
    home.lng        = g_gps->longitude;                                 // Lon * 10**7
    home.lat        = g_gps->latitude;                                  // Lat * 10**7
    home.alt        = 0;                                                        // Home is always 0

    // Save Home to EEPROM
    // -------------------
    // no need to save this to EPROM
    set_cmd_with_index(home, 0);

    // set inertial nav's home position
    inertial_nav.set_current_position(g_gps->longitude, g_gps->latitude);

    if (g.log_bitmask & MASK_LOG_CMD)
        Log_Write_Cmd(0, &home);

    // update navigation scalers.  used to offset the shrinking longitude as we go towards the poles
    scaleLongDown = longitude_scale(&home);
    scaleLongUp   = 1.0f/scaleLongDown;

    // Save prev loc this makes the calcs look better before commands are loaded
    prev_WP = home;

    // Load home for a default guided_WP
    // -------------
    guided_WP = home;
    guided_WP.alt += g.rtl_altitude;
}



