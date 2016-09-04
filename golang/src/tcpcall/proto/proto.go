/*
TCP Request-Reply Bridge - network protocol.

Author: Aleksey Morarash <aleksey.morarash@gmail.com>
Since: 4 Sep 2016
Copyright: 2016, Aleksey Morarash <aleksey.morarash@gmail.com>
*/

package proto

import (
	"encoding/binary"
	"errors"
	"sync"
	"time"
)

const (
	REQUEST              = 0
	REPLY                = 1
	ERROR                = 2
	CAST                 = 3
	FLOW_CONTROL_SUSPEND = 4
	FLOW_CONTROL_RESUME  = 5
	UPLINK_CAST          = 6
)

type SeqNum uint32

type Packet interface {
	Encode() []byte
}

type PacketRequest struct {
	SeqNum
	Deadline time.Time
	Request  []byte
}

type PacketReply struct {
	SeqNum
	Reply []byte
}

type PacketError struct {
	SeqNum
	Reason []byte
}

type PacketCast struct {
	SeqNum
	Request []byte
}

type PacketFlowControlSuspend struct {
	Duration time.Duration
}

type PacketFlowControlResume struct {
}

type PacketUplinkCast struct {
	Data []byte
}

var seq SeqNum
var seqMutex = sync.Mutex{}

// Create new request packet.
func NewRequest(request []byte, deadline time.Time) *PacketRequest {
	return &PacketRequest{getSeqNum(), deadline, request}
}

// Create new cast packet.
func NewCast(data []byte) *PacketCast {
	return &PacketCast{0, data}
}

// Encode Request packet for network.
func (p PacketRequest) Encode() []byte {
	res := make([]byte, len(p.Request)+13)
	res[0] = REQUEST
	binary.BigEndian.PutUint32(res[1:5], uint32(p.SeqNum))
	binary.BigEndian.PutUint64(res[5:13], uint64(p.Deadline.UnixNano()/1000))
	copy(res[13:], p.Request)
	return res
}

// Encode Reply packet for network.
func (p PacketReply) Encode() []byte {
	res := make([]byte, len(p.Reply)+5)
	res[0] = REPLY
	binary.BigEndian.PutUint32(res[1:5], uint32(p.SeqNum))
	copy(res[5:], p.Reply)
	return res
}

// Encode Cast packet for network.
func (p PacketCast) Encode() []byte {
	res := make([]byte, len(p.Request)+5)
	res[0] = CAST
	binary.BigEndian.PutUint32(res[1:5], uint32(p.SeqNum))
	copy(res[5:], p.Request)
	return res
}

// Encode Error packet for network.
func (p PacketError) Encode() []byte {
	res := make([]byte, len(p.Reason)+5)
	res[0] = ERROR
	binary.BigEndian.PutUint32(res[1:5], uint32(p.SeqNum))
	copy(res[5:], p.Reason)
	return res
}

// Encode Suspend packet for network.
func (p PacketFlowControlSuspend) Encode() []byte {
	res := make([]byte, 9)
	res[0] = FLOW_CONTROL_SUSPEND
	binary.BigEndian.PutUint64(res[1:], uint64(p.Duration.Nanoseconds()/1000000))
	return res
}

// Encode Resume packet for network.
func (p PacketFlowControlResume) Encode() []byte {
	return []byte{FLOW_CONTROL_RESUME}
}

// Encode Uplink Cast packet for network.
func (p PacketUplinkCast) Encode() []byte {
	res := make([]byte, len(p.Data)+1)
	res[0] = UPLINK_CAST
	copy(res[1:], p.Data)
	return res
}

// Decode network packet.
func Decode(bytes []byte) (ptype int, packet interface{}, err error) {
	if len(bytes) == 0 {
		return -1, nil, errors.New("bad packet: empty")
	}
	ptype = int(bytes[0])
	switch ptype {
	case REQUEST:
		if len(bytes) < 13 {
			return -1, nil, errors.New("bad Request packet: header too small")
		}
		seqnum := SeqNum(binary.BigEndian.Uint32(bytes[1:5]))
		micros := binary.BigEndian.Uint64(bytes[5:13])
		deadline := time.Unix(int64(micros/1000000), 0)
		return ptype, &PacketRequest{seqnum, deadline, bytes[13:]}, nil
	case CAST:
		if len(bytes) < 5 {
			return -1, nil, errors.New("bad Cast packet: header too small")
		}
		seqnum := SeqNum(binary.BigEndian.Uint32(bytes[1:5]))
		return ptype, &PacketCast{seqnum, bytes[5:]}, nil
	case REPLY:
		if len(bytes) < 5 {
			return -1, nil, errors.New("bad Reply packet: header too small")
		}
		seqnum := SeqNum(binary.BigEndian.Uint32(bytes[1:5]))
		return ptype, &PacketReply{seqnum, bytes[5:]}, nil
	case ERROR:
		if len(bytes) < 5 {
			return -1, nil, errors.New("bad Error packet: header too small")
		}
		seqnum := SeqNum(binary.BigEndian.Uint32(bytes[1:5]))
		return ptype, &PacketError{seqnum, bytes[5:]}, nil
	case FLOW_CONTROL_SUSPEND:
		if len(bytes) < 9 {
			return -1, nil, errors.New("bad Suspend packet: header too small")
		}
		millis := binary.BigEndian.Uint64(bytes[1:])
		return ptype, &PacketFlowControlSuspend{time.Millisecond * time.Duration(millis)}, nil
	case FLOW_CONTROL_RESUME:
		return ptype, &PacketFlowControlResume{}, nil
	case UPLINK_CAST:
		return ptype, &PacketUplinkCast{bytes[1:]}, nil
	}
	return -1, nil, errors.New("Not implemented")
}

// Generate sequence number (aka request ID).
func getSeqNum() SeqNum {
	seqMutex.Lock()
	defer seqMutex.Unlock()
	defer func() { seq++ }()
	return seq
}
