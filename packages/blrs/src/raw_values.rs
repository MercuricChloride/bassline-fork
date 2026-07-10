use std::cmp::Ordering;

macro_rules! impl_ordering {
    ($ty:ty) => {
        impl PartialEq for $ty {
            fn eq(&self, other: &Self) -> bool {
                self.cmp(other) == Ordering::Equal
            }
        }
        impl Eq for $ty {}
        impl PartialOrd for $ty {
            fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
                Some(self.cmp(other))
            }
        }
    };
}

impl_ordering!(Scalar<'_>);
impl_ordering!(Frame<'_>);
impl_ordering!(Kind<'_>);
impl_ordering!(Value<'_>);

pub enum Scalar<'a> {
    Nil,
    Int(&'a [u8]),
    Text(&'a [u8]),
    Symbol(&'a [u8]),
    Bytes(&'a [u8]),
}

pub enum Frame<'a> {
    List(&'a [Value<'a>]),
    Record(&'a [Value<'a>]),
    Dict(&'a [(Value<'a>, Value<'a>)]),
    Set(&'a [Value<'a>]),
}

pub enum Kind<'a> {
    Scalar(Scalar<'a>),
    Frame(Frame<'a>),
}

pub enum Value<'a> {
    Marked(Kind<'a>),
    Unmarked(Kind<'a>),
}

impl Ord for Scalar<'_> {
    fn cmp(&self, other: &Self) -> Ordering {
        match (self, other) {
            (Scalar::Nil, Scalar::Nil) => Ordering::Equal,
            (Scalar::Nil, _) => Ordering::Less,
            (_, Scalar::Nil) => Ordering::Greater,
            (Scalar::Int(a), Scalar::Int(b)) => a.cmp(b),
            (Scalar::Int(_), _) => Ordering::Less,
            (_, Scalar::Int(_)) => Ordering::Greater,
            (Scalar::Text(a), Scalar::Text(b)) => a.cmp(b),
            (Scalar::Text(_), _) => Ordering::Less,
            (_, Scalar::Text(_)) => Ordering::Greater,
            (Scalar::Symbol(a), Scalar::Symbol(b)) => a.cmp(b),
            (Scalar::Symbol(_), _) => Ordering::Less,
            (_, Scalar::Symbol(_)) => Ordering::Greater,
            (Scalar::Bytes(a), Scalar::Bytes(b)) => a.cmp(b),
        }
    }
}

impl Ord for Frame<'_> {
    fn cmp(&self, other: &Self) -> Ordering {
        match (self, other) {
            (Frame::List(a), Frame::List(b)) => a.cmp(b),
            (Frame::List(_), _) => Ordering::Less,
            (_, Frame::List(_)) => Ordering::Greater,
            (Frame::Record(a), Frame::Record(b)) => a.cmp(b),
            (Frame::Record(_), _) => Ordering::Less,
            (_, Frame::Record(_)) => Ordering::Greater,
            (Frame::Dict(a), Frame::Dict(b)) => a.cmp(b),
            (Frame::Dict(_), _) => Ordering::Less,
            (_, Frame::Dict(_)) => Ordering::Greater,
            (Frame::Set(a), Frame::Set(b)) => a.cmp(b),
        }
    }
}

impl Ord for Kind<'_> {
    fn cmp(&self, other: &Self) -> Ordering {
        match (self, other) {
            (Kind::Scalar(a), Kind::Scalar(b)) => a.cmp(b),
            (Kind::Frame(a), Kind::Frame(b)) => a.cmp(b),
            (Kind::Scalar(_), _) => Ordering::Less,
            (_, Kind::Scalar(_)) => Ordering::Greater,
        }
    }
}

impl Ord for Value<'_> {
    fn cmp(&self, other: &Self) -> Ordering {
        match (self, other) {
            (Value::Unmarked(a), Value::Unmarked(b)) => a.cmp(b),
            (Value::Marked(a), Value::Marked(b)) => a.cmp(b),
            (Value::Marked(a), Value::Unmarked(b)) => {
                match a.cmp(b) {
                    Ordering::Equal => Ordering::Greater,
                    ord => ord,
                }
            }
            (Value::Unmarked(a), Value::Marked(b)) => {
                match a.cmp(b) {
                    Ordering::Equal => Ordering::Less,
                    ord => ord,
                }
            }
        }
    }
}