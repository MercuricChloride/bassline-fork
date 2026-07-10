use crate::raw_values as rv;
use std::{collections::BTreeMap, io};

pub(crate) const TAG_OFFSET: u8 = 4;
pub(crate) const MARK_MASK: u8 = 0b00001000;
pub(crate) const LEN_MASK: u8 = 0b0000111;
pub(crate) const END: u8 = 0xa0;

pub struct ValueReader<'a> {
    frame_stack: Vec<rv::Frame<'a>>,
    bytes: io::Cursor<Vec<u8>>,
}

impl<'a> ValueReader<'a> {
    pub fn new(bytes: Vec<u8>) -> Self {
        Self { bytes: io::Cursor::new(bytes), frame_stack: Vec::new() }
    }
}

impl<'a> Iterator for ValueReader<'a> {
    type Item = Result<rv::Value<'a>, DecodeError>;
    
    fn next(&mut self) -> Option<Self::Item> {
        if self.bytes.position() >= self.bytes.get_ref().len() {
            return None;
        }

        let header = Header::read(self.bytes.get_ref());
        if let Err(e) = header {
            return Some(Err(e));
        }

        let header = header.unwrap()
    }
}

#[derive(Debug)]
pub enum DecodeError {
    InvalidTag,
    InvalidLength,
}

pub enum ScalarTag {
    Int,
    Text,
    Symbol,
    Bytes,
}
pub enum FrameTag {
    List,
    Record,
    Dict,
    Set,
}

pub enum Tag {
    Nil,
    Scalar(ScalarTag),
    Frame(FrameTag),
}

impl Tag {
    fn from_header(b: u8) -> Result<Self, DecodeError> {
        match b >> TAG_OFFSET {
            1 => Ok(Tag::Nil),
            2 => Ok(Tag::Scalar(ScalarTag::Int)),
            3 => Ok(Tag::Scalar(ScalarTag::Text)),
            4 => Ok(Tag::Scalar(ScalarTag::Symbol)),
            5 => Ok(Tag::Scalar(ScalarTag::Bytes)),
            6 => Ok(Tag::Frame(FrameTag::List)),
            7 => Ok(Tag::Frame(FrameTag::Record)),
            8 => Ok(Tag::Frame(FrameTag::Dict)),
            9 => Ok(Tag::Frame(FrameTag::Set)),
            _ => Err(DecodeError::InvalidTag),
        }
    }
}

pub enum Length {
    Empty,
    Inline(u8),
    Small(u8),
    Large(u32),
}

pub struct Header {
    pub tag: Tag,
    pub mark: bool,
    pub len: Length,
    pub offset: usize
}

impl Header {
    pub fn new(tag: Tag, mark: bool, len: Length) -> Self {
        let offset = match len {
            Length::Empty => 1,
            Length::Inline(n) => 1 + n as usize,
            Length::Small(n) => 2 + n as usize,
            Length::Large(n) => 5 + n as usize,
        };
        Self { tag, mark, len, offset }
    }

    pub fn read(bytes: &[u8]) -> Result<Self, DecodeError> {
        let header = bytes[0];
        let tag = Tag::from_header(header)?;
        let mark = header & MARK_MASK != 0;
        let header_len = bytes[0] & LEN_MASK;

        if header_len == 0 {
            let len = Length::Empty;
            return Ok(Header::new(tag, mark, len));
        }

        match tag {
            Tag::Nil => return Err(DecodeError::InvalidLength),
            Tag::Frame(_) => return Err(DecodeError::InvalidLength),
            _ => {}
        }

        if header_len < 7 {
            let len = Length::Inline(header_len);
            return Ok(Header::new(tag, mark, len));
        }

        let next_byte = bytes[1];

        if next_byte < 255 {
            let len = Length::Small(next_byte);
            return Ok(Header::new(tag, mark, len));
        } else {
            let len_bytes = &bytes[2..5];
            let len =
                u32::from_be_bytes(len_bytes.try_into().expect("slice with incorrect length"));
            let len = Length::Large(len);
            return Ok(Header::new(tag, mark, len));
        }
    }
}