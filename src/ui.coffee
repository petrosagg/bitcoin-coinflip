crypto = require 'crypto'

_ = require 'lodash'
low = require 'lowdb'
colors = require 'colors/safe'
inquirer = require 'inquirer'
bitcoin = require 'bitcoinjs-lib'
{ blockexplorer } = require('blockchain.info')

NONCE_SIZE = 16

state = low('state.json')

state.defaults({
	privateKey: null
	games: []
}).write()

utxos = []
keyPair = null
address = null

initKeyPair = ->
	privateKey = state.get('privateKey').value()
	if privateKey is null
		console.log('Creating new wallet..')
		keyPair = bitcoin.ECPair.makeRandom()
		state.set('privateKey', keyPair.toWIF()).write()
	else
		keyPair = bitcoin.ECPair.fromWIF(privateKey)
		console.log('Loaded wallet from disk')

	address = keyPair.getAddress()

formatSatoshi = (satoshi) -> "#{satoshi} shatoshi (#{(satoshi / 1e9).toFixed(3)}BTC)"

createGame = ->
	console.log(utxos)
	utxoChoices = _.keyBy(utxos, (tx) -> "#{formatSatoshi(tx.value)} from #{tx.tx_hash}")

	questions = [
		{
			name: 'opponent'
			message: 'Who are you playing against?'
			default: 'Bob'
		},
		{
			type: 'list'
			name: 'ourInput'
			message: 'How much will you bet?'
			choices: Object.keys(utxoChoices)
			filter: (choice) -> utxoChoices[choice]
		},
		{
			name: 'theirAmount'
			message: ({opponent}) -> "How much satoshi will #{opponent} bet?"
			filter: Number
			default: (ans) -> ans.ourInput.value
		},
		{
			type: 'list'
			name: 'bet'
			message: 'Heads or Tails?'
			choices: _.shuffle([ 'Heads', 'Tails' ])
			filter: (side) ->
				value = if side is 'Heads' then 0 else 1

				buf = Buffer.alloc(NONCE_SIZE + value)
				crypto.randomFillSync(buf)

				commit = bitcoin.crypto.hash160(buf).toString('hex')
				console.log('Your commitment is:', commit)

				return {
					commit: commit
					nonce: buf.toString('hex')
					value: value
				}
		},
		{
			name: 'theirAddress'
			message: (answers) ->
				console.log('Your info:')
				console.log('Address:', address)
				console.log('Commitment:', answers.bet.commit)
				return "What is #{answers.opponent}'s bitcoin address?"
			validate: (addr) ->
				try
					bitcoin.address.fromBase58Check(addr)
				catch
					return 'Invalid bitcoin address'
				return true
		},
		{
			name: 'theirCommit'
			message: ({opponent}) ->"What is #{opponent}'s commitment?"
			validate: (commit) ->
				buf = Buffer.from(commit, 'hex')
				if buf.length isnt NONCE_SIZE and buf.length isnt NONCE_SIZE + 1
					return 'Invalid commitment'
				return true
		},
	]
	inquirer.prompt(questions)
	.then (game) ->
		game.state = 'new'
		console.log('Saving game state')
		state.get('games').push(game).write()
		return game

checkBalance = ->
	console.log('Checking available UTXOs..')

	blockexplorer.getUnspentOutputs(address, confirmations: 1)
	.get('unspent_outputs')
	.then (result) ->
		utxos = result
	.catch (e) ->
		if e is 'No free outputs to spend'
			console.log(colors.red("You don't have any funds to play with. Send some funds and try again later"))
			console.log(colors.cyan('~ Make sure you send the exact amount you want to bet with a single UTXO. Change is not supported ~'))
		else
			console.log('Unexpected error:', e)
		throw e

chooseGame = ->
	games = state.get('games').value()

	if games.length is 0
		console.log('> You have no ongoing games')
	else
		console.log(colors.green('> You have', games.length, 'ongoing games'))

	inquirer.prompt([
		{
			type: 'confirm'
			name: 'newGame'
			message: 'Would you like to start a new game?'
			default: true
		}
	]).then ({newGame}) ->
		if newGame
			return createGame()
		else if games.length > 0
			gameChoices = _.keyBy(games, (g) -> "#{g.opponent} - #{g.amount}BTC")

			questions = [
				{
					type: 'list'
					name: 'game'
					message: 'Choose game to resume'
					choices: Object.keys(gameChoices)
					filter: (choice) -> gameChoices[choice]
				}
			]
			return inquirer.prompt(questions).then((answer) -> answer.game)
		else
			throw new Error()

finalizeGame = (game) ->
	ourCommit = Buffer.from(game.bet.commit, 'hex')
	theirCommit = Buffer.from(game.theirCommit, 'hex')

	p2shAddress = createCoinflipScript(address, game.theirAddress, outCommit, theirCommit)

	# deterministically decide who will generate the tx and who will wait
	shouldCreateTx = Boolean((game.ourCommit[0] ^ game.theirCommit[0]) & 1)

	if shouldCreateTx
		sign
	else # wait for signed tx
		inquirer.prompt(
			name: 'input'
			message: "Enter #{game.opponent}'s signed input"
		)
		.then ({input}) ->
			console.log(input)
		
main = ->
	console.log(colors.bold('- Welcome to bitcoin coinflip!'))
	initKeyPair()

	checkBalance()
	.then(chooseGame)
	.catch ->
		console.log('Goodbye')
		process.exit()

main()
