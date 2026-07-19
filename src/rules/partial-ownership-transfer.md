# `partial-ownership-transfer`

[Rule index](RULES.md)

Reports returning one owned field from a value whose cleanup contract releases
additional owned fields, without first cleaning or transferring the owner.

**Why it matters.** Moving one field does not implicitly release the owner's
remaining resources, so the omitted fields leak when the owner is dropped.

**When it matters.** The rule requires a visible returned field and a visible
cleanup method for another field of the returned value's type.
