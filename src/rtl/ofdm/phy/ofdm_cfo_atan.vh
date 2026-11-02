// CFO atan turns: one full turn=2^32.
function signed [33:0] cfo_atan_word;
    input [4:0] index;
    begin
        case (index)
            5'd0: cfo_atan_word=34'sd536870912;
            5'd1: cfo_atan_word=34'sd316933406;
            5'd2: cfo_atan_word=34'sd167458907;
            5'd3: cfo_atan_word=34'sd85004756;
            5'd4: cfo_atan_word=34'sd42667331;
            5'd5: cfo_atan_word=34'sd21354465;
            5'd6: cfo_atan_word=34'sd10679838;
            5'd7: cfo_atan_word=34'sd5340245;
            5'd8: cfo_atan_word=34'sd2670163;
            5'd9: cfo_atan_word=34'sd1335087;
            5'd10: cfo_atan_word=34'sd667544;
            5'd11: cfo_atan_word=34'sd333772;
            5'd12: cfo_atan_word=34'sd166886;
            5'd13: cfo_atan_word=34'sd83443;
            5'd14: cfo_atan_word=34'sd41722;
            5'd15: cfo_atan_word=34'sd20861;
            5'd16: cfo_atan_word=34'sd10430;
            5'd17: cfo_atan_word=34'sd5215;
            5'd18: cfo_atan_word=34'sd2608;
            5'd19: cfo_atan_word=34'sd1304;
            5'd20: cfo_atan_word=34'sd652;
            5'd21: cfo_atan_word=34'sd326;
            5'd22: cfo_atan_word=34'sd163;
            5'd23: cfo_atan_word=34'sd81;
            5'd24: cfo_atan_word=34'sd41;
            5'd25: cfo_atan_word=34'sd20;
            5'd26: cfo_atan_word=34'sd10;
            5'd27: cfo_atan_word=34'sd5;
            5'd28: cfo_atan_word=34'sd3;
            5'd29: cfo_atan_word=34'sd1;
            5'd30: cfo_atan_word=34'sd1;
            5'd31: cfo_atan_word=34'sd0;
            default: cfo_atan_word=34'sd0;
        endcase
    end
endfunction
