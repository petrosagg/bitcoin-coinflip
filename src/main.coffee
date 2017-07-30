bitcoin = require 'bitcoinjs-lib'
crypto = require 'crypto'
{ crypto: Signature, Script, Transaction, PrivateKey } = require 'bitcore-lib'

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

# Assume a UTXO exists that sends 1BTC to the P2SH address calculated above.
# When this runs in production, this UTXO will have inputs from Alice and Bob,
# which is how they place their bets.
p2shUtxoWith1BTC = new Transaction.UnspentOutput(
	txId: 'a477af6b2667c29670467e4e0728b685ee07b240235771862318e29ddbe58458'
	outputIndex: 0
	script: Script.fromBuffer(p2shPubScript)
	satoshis: 1e8
)

# Calculate who won
if aValue is bValue
	console.log('Alice wins')
	winnerKeyPair = PrivateKey.fromWIF(aKeyPair.toWIF())
else
	console.log('Bob wins')
	winnerKeyPair = PrivateKey.fromWIF(bKeyPair.toWIF())

# Now let's create a transaction that tries to spend the bet
tx = new Transaction()
.from(p2shUtxoWith1BTC)
.to(winnerKeyPair.toAddress(), 1e8)

# Sign the transaction with Alice's private key
sigtype = Signature.SIGHASH_ALL
signature = Transaction.Sighash.sign(tx, winnerKeyPair, sigtype, 0, Script.fromBuffer(redeemPubScript))
signatureBuffer = Buffer.concat([ signature.toDER(), Buffer.from([ sigtype ]) ])

# Construct the sigScript containing the serialised redeemScript, the two
# random inputs and Alice's signature
p2shScriptSig = Script()
.add(signatureBuffer)
.add(winnerKeyPair.toPublicKey().toBuffer())
.add(Buffer.from(bNonce, 'hex'))
.add(Buffer.from(aNonce, 'hex'))
.add(redeemPubScript)

interpreter = Script.Interpreter()
flags = Script.Interpreter.SCRIPT_VERIFY_P2SH
verified = interpreter.verify(p2shScriptSig, Script.fromBuffer(p2shPubScript), tx, 0, flags)

console.log('Verifying spending transaction:', verified, interpreter.errstr)
