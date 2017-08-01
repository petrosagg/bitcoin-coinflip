bitcoin = require 'bitcoinjs-lib'
crypto = require 'crypto'
{ Script, Transaction } = require 'bitcore-lib'

coinflip = require './coinflip'

# Number of random bytes provided by each party
NONCE_SIZE = 16

makeNonce = (value) ->
	buf = Buffer.allocUnsafe(NONCE_SIZE + value)
	crypto.randomFillSync(buf)
	return buf.toString('hex')

nonce2commit = (nonce) -> bitcoin.crypto.hash160(Buffer.from(nonce, 'hex')).toString('hex')

setup = (value) ->
	nonce = makeNonce(value)
	return [ bitcoin.ECPair.makeRandom(), nonce, nonce2commit(nonce) ]

# Alice and Bob each select a random bit
aValue = 1
bValue = 0

# Generate random keypairs for Alice and Bob
[ aKeyPair, aNonce, aCommit ] = setup(aValue)
[ bKeyPair, bNonce, bCommit ] = setup(bValue)

if bCommit < aCommit
	[ aKeyPair, bKeyPair ] = [ bKeyPair, aKeyPair ]
	[ aNonce, bNonce ] = [ bNonce, aNonce ]
	[ aCommit, bCommit ] = [ bCommit, aCommit ]

# The comments bellow follow the stack contents as the Bitcoin Script executes

redeemPubScript = coinflip.createRedeemPubScript(aCommit, bCommit, aKeyPair.getAddress(), bKeyPair.getAddress())

p2shPubScript = bitcoin.script.scriptHash.output.encode(bitcoin.crypto.hash160(redeemPubScript))

p2shAddress = bitcoin.address.fromOutputScript(p2shPubScript)

console.log('Alice')
console.log('    Private Key:', aKeyPair.toWIF())
console.log('          Value:', aValue)
console.log('         Buffer:', aNonce)
console.log('     Commitment:', aCommit)
console.log('Bob')
console.log('    Private Key:', bKeyPair.toWIF())
console.log('          Value:', bValue)
console.log('         Buffer:', bNonce)
console.log('     Commitment:', bCommit)
console.log('')
console.log('Funding address:', p2shAddress)
console.log('')

# Calculate who won
if aValue is bValue
	console.log('Alice wins')
	winnerKeyPair = aKeyPair
else
	console.log('Bob wins')
	winnerKeyPair = bKeyPair

# Now let's create a transaction that tries to spend the bet
txb = new bitcoin.TransactionBuilder()
txb.addInput('a477af6b2667c29670467e4e0728b685ee07b240235771862318e29ddbe58458', 0)
txb.addOutput(winnerKeyPair.getAddress().toString(), 1e8)
tx = txb.buildIncomplete()

coinflip.sign(tx, 0, winnerKeyPair, aNonce, bNonce, aKeyPair.getAddress(), bKeyPair.getAddress())

interpreter = Script.Interpreter()
flags = Script.Interpreter.SCRIPT_VERIFY_P2SH
verified = interpreter.verify(Script.fromBuffer(tx.ins[0].script), Script.fromBuffer(p2shPubScript), Transaction(tx.toHex()), 0, flags)

console.log('Verifying spending transaction:', verified, interpreter.errstr)
