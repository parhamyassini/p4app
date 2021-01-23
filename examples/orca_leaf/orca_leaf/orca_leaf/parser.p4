parser ParserImpl(packet_in packet, out headers hdr, inout metadata meta, inout standard_metadata_t standard_metadata) {
    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition parse_orca_status;
    }

    state parse_orca_status {
        packet.extract(hdr.orca_status);
        transition select(hdr.orca_status.leaf_status_bit){
            1: parse_leaf_ds;
            0: parse_leaf_us;
        }
    }
    
    state parse_leaf_ds {
        packet.extract(hdr.orca_label.leaf_label);
        transition accept;
    }

    state parse_leaf_us{
        packet.extract(hdr.orca_label.src_label);
        transition accept;
    }

    state start {
        transition parse_ethernet;
    }
}

control DeparserImpl(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.orca_status);
        packet.emit(hdr.orca_label);
    }
}

control verifyChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}

control computeChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}
