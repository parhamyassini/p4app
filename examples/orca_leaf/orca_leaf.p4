#include <core.p4>
#include <v1model.p4>

#include "header.p4"
#include "parser.p4"

control egress(inout headers hdr, inout metadata meta, inout standard_metadata_t standard_metadata) {
    apply {  }
}


@pure
extern void output_port_select(in bit<NUM_SW_PORTS> bitmap);// the extern action for bitmap-based port selection

control ingress(inout headers hdr, inout metadata meta, inout standard_metadata_t standard_metadata) {
    action _drop() {
        mark_to_drop(standard_metadata);
    }

    action forward_downstream() {
        meta.portmap_metadata.out_portmap = (bit <NUM_SW_PORTS>)hdr.orca_label.src_label.leaf_us | meta.portmap_metadata.out_portmap;
        //bit_or(meta.out_portmap, meta.out_portmap, hdr.src_label.leaf_ds); // US ports are 0, DS ports on low order bits of out_portmap 
        output_port_select(meta.portmap_metadata.out_portmap);
    }

    action forward_upstream() {
        meta.portmap_metadata.out_portmap = (bit <NUM_SW_PORTS>) hdr.orca_label.src_label.leaf_us << NUM_LEAF_DS;
        //shift_left(meta.out_portmap, hdr.src_label.leaf_us, NUM_LEAF_DS); // DS ports are 0, US ports on high order bits of out_portmap 
        output_port_select(meta.portmap_metadata.out_portmap);
    }

    action set_agent_port(bit<9> port) {
        standard_metadata.egress_spec = port;
    }

    action set_default_port() {
        standard_metadata.egress_spec = DEFAULT_AGENT_PORT;
    }
    
    table forward_agent {
        actions = {
            set_agent_port;
            set_default_port;
        }
        key = {
            hdr.orca_status.leaf_status_bit: exact;
        }
        size = 1;
        default_action = set_default_port();
    }
    apply {
        if (hdr.orca_label.src_label.isValid()) {
            // Assuming switch port connections: 
            // Ports [0, NUM_DS): connected to servers
            // Ports [NUM_DS, NUM_DS+NUM_US): connected to spine switches 
            if (standard_metadata.ingress_port < NUM_LEAF_DS) { // pkt from server, frwrd upstream
                forward_upstream();
            } else {
                forward_agent.apply();
            }
        } else {
            if (hdr.orca_label.leaf_label.isValid()) {
                forward_downstream();
            }
        }
    }
}

V1Switch(ParserImpl(), verifyChecksum(), ingress(), egress(), computeChecksum(), DeparserImpl()) main;
